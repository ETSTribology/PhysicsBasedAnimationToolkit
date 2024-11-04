// clang-format off
#include "pbat/gpu/DisableWarnings.h"
// clang-format on

#include "Kernels.cuh"
#include "VbdImpl.cuh"
#include "pbat/gpu/common/Cuda.cuh"
#include "pbat/gpu/common/Eigen.cuh"
#include "pbat/math/linalg/mini/Mini.h"
#include "pbat/sim/vbd/Kernels.h"

#include <cuda/api.hpp>
// #include <thrust/async/copy.h>
#include <thrust/async/for_each.h>
#include <thrust/execution_policy.h>

namespace pbat {
namespace gpu {
namespace vbd {

VbdImpl::VbdImpl(
    Eigen::Ref<GpuMatrixX const> const& Xin,
    Eigen::Ref<GpuIndexMatrixX const> const& Vin,
    Eigen::Ref<GpuIndexMatrixX const> const& Fin,
    Eigen::Ref<GpuIndexMatrixX const> const& Tin)
    : X(Xin),
      V(Vin),
      F(Fin),
      T(Tin),
      mPositionsAtT(Xin.cols()),
      mInertialTargetPositions(Xin.cols()),
      mChebyshevPositionsM2(Xin.cols()),
      mChebyshevPositionsM1(Xin.cols()),
      mVelocitiesAtT(Xin.cols()),
      mVelocities(Xin.cols()),
      mExternalAcceleration(Xin.cols()),
      mMass(Xin.cols()),
      mQuadratureWeights(Tin.cols()),
      mShapeFunctionGradients(Tin.cols() * 4 * 3),
      mLameCoefficients(2 * Tin.cols()),
      mDetHZero(GpuScalar{1e-10}),
      mVertexTetrahedronPrefix(Xin.cols() + 1),
      mVertexTetrahedronNeighbours(),
      mVertexTetrahedronLocalVertexIndices(),
      mRayleighDamping(GpuScalar{0}),
      mCollisionPenalty(GpuScalar{1e3}),
      mMaxCollidingTrianglesPerVertex(8),
      mCollidingTriangles(8 * Xin.cols()),
      mCollidingTriangleCount(Xin.cols()),
      mPartitions(),
      mInitializationStrategy(EInitializationStrategy::AdaptiveVbd),
      mGpuThreadBlockSize(64),
      mStream(common::Device(common::EDeviceSelectionPreference::HighestComputeCapability)
                  .create_stream(/*synchronize_with_default_stream=*/false))
{
    mPositionsAtT = X.x;
    mVelocitiesAtT.SetConstant(GpuScalar(0));
    mVelocities.SetConstant(GpuScalar(0));
    mExternalAcceleration.SetConstant(GpuScalar(0));
    mMass.SetConstant(GpuScalar(1e3));
}

void VbdImpl::Step(GpuScalar dt, GpuIndex iterations, GpuIndex substeps, GpuScalar rho)
{
    GpuScalar sdt                        = dt / static_cast<GpuScalar>(substeps);
    GpuScalar sdt2                       = sdt * sdt;
    GpuIndex const nVertices             = static_cast<GpuIndex>(X.NumberOfPoints());
    bool const bUseChebyshevAcceleration = rho > GpuScalar{0} and rho < GpuScalar{1};

    kernels::BackwardEulerMinimization bdf{};
    bdf.dt                              = sdt;
    bdf.dt2                             = sdt2;
    bdf.m                               = mMass.Raw();
    bdf.xtilde                          = mInertialTargetPositions.Raw();
    bdf.xt                              = mPositionsAtT.Raw();
    bdf.x                               = X.x.Raw();
    bdf.T                               = T.inds.Raw();
    bdf.wg                              = mQuadratureWeights.Raw();
    bdf.GP                              = mShapeFunctionGradients.Raw();
    bdf.lame                            = mLameCoefficients.Raw();
    bdf.detHZero                        = mDetHZero;
    bdf.GVTp                            = mVertexTetrahedronPrefix.Raw();
    bdf.GVTn                            = mVertexTetrahedronNeighbours.Raw();
    bdf.GVTilocal                       = mVertexTetrahedronLocalVertexIndices.Raw();
    bdf.kD                              = mRayleighDamping;
    bdf.kC                              = mCollisionPenalty;
    bdf.nMaxCollidingTrianglesPerVertex = mMaxCollidingTrianglesPerVertex;
    bdf.FC                              = mCollidingTriangles.Raw();
    bdf.nCollidingTriangles             = mCollidingTriangleCount.Raw();
    bdf.F                               = F.inds.Raw();

    // NOTE:
    // For some reason, thrust::async::copy does not play well with cuda-api-wrapper streams. I am
    // guessing it has to do with synchronize_with_default_stream=false?
    mStream.device().make_current();
    for (auto s = 0; s < substeps; ++s)
    {
        using namespace pbat::math::linalg::mini;
        // Store previous positions
        for (auto d = 0; d < X.x.Dimensions(); ++d)
        {
            cuda::memory::async::copy(
                thrust::raw_pointer_cast(mPositionsAtT[d].data()),
                thrust::raw_pointer_cast(X.x[d].data()),
                X.x.Size() * sizeof(GpuScalar),
                mStream);
        }
        // Compute inertial target positions
        thrust::device_event e = thrust::async::for_each(
            // Share thrust's underlying CUDA stream with cuda-api-wrappers
            thrust::device.on(mStream.handle()),
            thrust::make_counting_iterator<GpuIndex>(0),
            thrust::make_counting_iterator<GpuIndex>(nVertices),
            [xt     = mPositionsAtT.Raw(),
             vt     = mVelocities.Raw(),
             aext   = mExternalAcceleration.Raw(),
             xtilde = mInertialTargetPositions.Raw(),
             dt     = sdt,
             dt2    = sdt2] PBAT_DEVICE(auto i) {
                using pbat::sim::vbd::kernels::InertialTarget;
                auto y = InertialTarget(
                    FromBuffers<3, 1>(xt, i),
                    FromBuffers<3, 1>(vt, i),
                    FromBuffers<3, 1>(aext, i),
                    dt,
                    dt2);
                ToBuffers(y, xtilde, i);
            });
        // Initialize block coordinate descent's, i.e. BCD's, solution
        e = thrust::async::for_each(
            thrust::device.on(mStream.handle()),
            thrust::make_counting_iterator<GpuIndex>(0),
            thrust::make_counting_iterator<GpuIndex>(nVertices),
            [xt       = mPositionsAtT.Raw(),
             vtm1     = mVelocitiesAtT.Raw(),
             vt       = mVelocities.Raw(),
             aext     = mExternalAcceleration.Raw(),
             x        = X.x.Raw(),
             dt       = sdt,
             dt2      = sdt2,
             strategy = mInitializationStrategy] PBAT_DEVICE(auto i) {
                using pbat::sim::vbd::kernels::InitialPositionsForSolve;
                auto x0 = InitialPositionsForSolve(
                    FromBuffers<3, 1>(xt, i),
                    FromBuffers<3, 1>(vtm1, i),
                    FromBuffers<3, 1>(vt, i),
                    FromBuffers<3, 1>(aext, i),
                    dt,
                    dt2,
                    strategy);
                ToBuffers(x0, x, i);
            });
        // Initialize Chebyshev semi-iterative method
        GpuScalar rho2 = rho * rho;
        GpuScalar omega{};
        auto kDynamicSharedMemoryCapacity = static_cast<cuda::memory::shared::size_t>(
            mGpuThreadBlockSize * bdf.ExpectedSharedMemoryPerThreadInBytes());
        // Minimize Backward Euler, i.e. BDF1, objective
        for (auto k = 0; k < iterations; ++k)
        {
            using pbat::sim::vbd::kernels::ChebyshevOmega;
            if (bUseChebyshevAcceleration)
                omega = ChebyshevOmega(k, rho2, omega);

            for (auto& partition : mPartitions)
            {
                bdf.partition = partition.Raw();
                auto const nVerticesInPartition =
                    static_cast<cuda::grid::dimension_t>(partition.Size());
                auto bcdLaunchConfiguration =
                    cuda::launch_config_builder()
                        .block_size(mGpuThreadBlockSize)
                        .dynamic_shared_memory_size(kDynamicSharedMemoryCapacity)
                        .grid_size(nVerticesInPartition)
                        .build();
                mStream.enqueue.kernel_launch(
                    kernels::MinimizeBackwardEuler,
                    bcdLaunchConfiguration,
                    bdf);
            }

            if (bUseChebyshevAcceleration)
            {
                e = thrust::async::for_each(
                    thrust::device.on(mStream.handle()),
                    thrust::make_counting_iterator<GpuIndex>(0),
                    thrust::make_counting_iterator<GpuIndex>(nVertices),
                    [k     = k,
                     omega = omega,
                     xkm2  = mChebyshevPositionsM2.Raw(),
                     xkm1  = mChebyshevPositionsM1.Raw(),
                     xk    = X.x.Raw()] PBAT_DEVICE(auto i) {
                        using pbat::sim::vbd::kernels::ChebyshevUpdate;
                        auto xkm2i = FromBuffers<3, 1>(xkm2, i);
                        auto xkm1i = FromBuffers<3, 1>(xkm1, i);
                        auto xki   = FromBuffers<3, 1>(xk, i);
                        ChebyshevUpdate(k, omega, xkm2i, xkm1i, xki);
                    });
            }
        }
        // Update velocities
        for (auto d = 0; d < mVelocities.Dimensions(); ++d)
        {
            cuda::memory::async::copy(
                thrust::raw_pointer_cast(mVelocitiesAtT[d].data()),
                thrust::raw_pointer_cast(mVelocities[d].data()),
                mVelocities.Size() * sizeof(GpuScalar),
                mStream);
        }
        e = thrust::async::for_each(
            thrust::device.on(mStream.handle()),
            thrust::make_counting_iterator<GpuIndex>(0),
            thrust::make_counting_iterator<GpuIndex>(nVertices),
            [xt = mPositionsAtT.Raw(), x = X.x.Raw(), v = mVelocities.Raw(), dt = sdt] PBAT_DEVICE(
                auto i) {
                using pbat::sim::vbd::kernels::IntegrateVelocity;
                auto vtp1 =
                    IntegrateVelocity(FromBuffers<3, 1>(xt, i), FromBuffers<3, 1>(x, i), dt);
                ToBuffers(vtp1, v, i);
            });
    }
    mStream.synchronize();
}

void VbdImpl::SetPositions(Eigen::Ref<GpuMatrixX const> const& Xin)
{
    common::ToBuffer(Xin, X.x);
}

void VbdImpl::SetVelocities(Eigen::Ref<GpuMatrixX const> const& v)
{
    common::ToBuffer(v, mVelocities);
}

void VbdImpl::SetExternalAcceleration(Eigen::Ref<GpuMatrixX const> const& aext)
{
    common::ToBuffer(aext, mExternalAcceleration);
}

void VbdImpl::SetMass(Eigen::Ref<GpuVectorX const> const& m)
{
    common::ToBuffer(m, mMass);
}

void VbdImpl::SetQuadratureWeights(Eigen::Ref<GpuVectorX const> const& wg)
{
    common::ToBuffer(wg, mQuadratureWeights);
}

void VbdImpl::SetShapeFunctionGradients(Eigen::Ref<GpuMatrixX const> const& GP)
{
    common::ToBuffer(GP, mShapeFunctionGradients);
}

void VbdImpl::SetLameCoefficients(Eigen::Ref<GpuMatrixX const> const& l)
{
    common::ToBuffer(l, mLameCoefficients);
}

void VbdImpl::SetNumericalZeroForHessianDeterminant(GpuScalar zero)
{
    mDetHZero = zero;
}

void VbdImpl::SetVertexTetrahedronAdjacencyList(
    Eigen::Ref<GpuIndexVectorX const> const& GVTp,
    Eigen::Ref<GpuIndexVectorX const> const& GVTn,
    Eigen::Ref<GpuIndexVectorX const> const& GVTilocal)
{
    if (GVTn.size() != GVTilocal.size())
    {
        std::ostringstream ss{};
        ss << "Expected vertex-tetrahedron adjacency graph's neighbour array and data (ilocal) "
              "array to have the same size, but got neighbours="
           << GVTn.size() << ", ilocal=" << GVTilocal.size() << " \n";
        throw std::invalid_argument(ss.str());
    }

    common::ToBuffer(GVTp, mVertexTetrahedronPrefix);
    mVertexTetrahedronNeighbours.Resize(GVTn.size());
    mVertexTetrahedronLocalVertexIndices.Resize(GVTilocal.size());
    common::ToBuffer(GVTn, mVertexTetrahedronNeighbours);
    common::ToBuffer(GVTilocal, mVertexTetrahedronLocalVertexIndices);
}

void VbdImpl::SetRayleighDampingCoefficient(GpuScalar kD)
{
    mRayleighDamping = kD;
}

void VbdImpl::SetVertexPartitions(std::vector<std::vector<GpuIndex>> const& partitions)
{
    mPartitions.resize(partitions.size());
    for (auto p = 0; p < partitions.size(); ++p)
    {
        mPartitions[p].Resize(partitions[p].size());
        thrust::copy(partitions[p].begin(), partitions[p].end(), mPartitions[p].Data());
    }
}

void VbdImpl::SetInitializationStrategy(EInitializationStrategy strategy)
{
    mInitializationStrategy = strategy;
}

void VbdImpl::SetBlockSize(GpuIndex blockSize)
{
    mGpuThreadBlockSize = blockSize;
}

common::Buffer<GpuScalar, 3> const& VbdImpl::GetVelocity() const
{
    return mVelocities;
}

common::Buffer<GpuScalar, 3> const& VbdImpl::GetExternalAcceleration() const
{
    return mExternalAcceleration;
}

common::Buffer<GpuScalar> const& VbdImpl::GetMass() const
{
    return mMass;
}

common::Buffer<GpuScalar> const& VbdImpl::GetShapeFunctionGradients() const
{
    return mShapeFunctionGradients;
}

common::Buffer<GpuScalar> const& VbdImpl::GetLameCoefficients() const
{
    return mLameCoefficients;
}

std::vector<common::Buffer<GpuIndex>> const& VbdImpl::GetPartitions() const
{
    return mPartitions;
}

} // namespace vbd
} // namespace gpu
} // namespace pbat

#include "pbat/common/Eigen.h"
#include "tests/Fem.h"

#include <Eigen/SparseCore>
#include <doctest/doctest.h>
#include <span>
#include <vector>

TEST_CASE("[gpu][vbd] Vbd")
{
    using pbat::GpuIndex;
    using pbat::GpuIndexMatrixX;
    using pbat::GpuMatrixX;
    using pbat::GpuScalar;
    using pbat::GpuVectorX;
    using pbat::Index;
    using pbat::Scalar;
    using pbat::common::ToEigen;
    // Arrange
    // Cube mesh
    GpuMatrixX P(3, 8);
    GpuIndexMatrixX V(1, 8);
    GpuIndexMatrixX T(4, 5);
    GpuIndexMatrixX F(3, 12);
    // clang-format off
    P << 0.f, 1.f, 0.f, 1.f, 0.f, 1.f, 0.f, 1.f,
         0.f, 0.f, 1.f, 1.f, 0.f, 0.f, 1.f, 1.f,
         0.f, 0.f, 0.f, 0.f, 1.f, 1.f, 1.f, 1.f;
    T << 0, 3, 5, 6, 0,
         1, 2, 4, 7, 5,
         3, 0, 6, 5, 3,
         5, 6, 0, 3, 6;
    F << 0, 1, 1, 3, 3, 2, 2, 0, 0, 0, 4, 5,
         1, 5, 3, 7, 2, 6, 0, 4, 3, 2, 5, 7,
         4, 4, 5, 5, 7, 7, 6, 6, 1, 3, 6, 6;
    // clang-format on
    V.reshaped().setLinSpaced(0, static_cast<GpuIndex>(P.cols() - 1));
    // Parallel graph information
    using SparseMatrixType = Eigen::SparseMatrix<GpuIndex, Eigen::ColMajor>;
    using TripletType      = Eigen::Triplet<GpuIndex, typename SparseMatrixType::StorageIndex>;
    SparseMatrixType G(T.cols(), P.cols());
    std::vector<TripletType> Gei{};
    for (auto e = 0; e < T.cols(); ++e)
    {
        for (auto ilocal = 0; ilocal < T.rows(); ++ilocal)
        {
            auto i = T(ilocal, e);
            Gei.push_back(TripletType{e, i, ilocal});
        }
    }
    G.setFromTriplets(Gei.begin(), Gei.end());
    assert(G.isCompressed());
    std::span<GpuIndex> vertexTetrahedronPrefix{
        G.outerIndexPtr(),
        static_cast<std::size_t>(G.outerSize() + 1)};
    std::span<GpuIndex> vertexTetrahedronNeighbours{
        G.innerIndexPtr(),
        static_cast<std::size_t>(G.nonZeros())};
    std::span<GpuIndex> vertexTetrahedronLocalVertexIndices{
        G.valuePtr(),
        static_cast<std::size_t>(G.nonZeros())};
    std::vector<std::vector<GpuIndex>> partitions{};
    partitions.push_back({2, 7, 4, 1});
    partitions.push_back({0});
    partitions.push_back({5});
    partitions.push_back({6});
    partitions.push_back({3});
    // Material parameters
    using pbat::gpu::vbd::tests::LinearFemMesh;
    LinearFemMesh mesh{P, T};
    GpuVectorX wg     = mesh.QuadratureWeights();
    GpuMatrixX GP     = mesh.ShapeFunctionGradients();
    auto constexpr Y  = GpuScalar{1e6};
    auto constexpr nu = GpuScalar{0.45};
    GpuMatrixX lame   = mesh.LameCoefficients(Y, nu);
    // Problem parameters
    GpuMatrixX aext(3, P.cols());
    aext.colwise()    = Eigen::Vector<GpuScalar, 3>{GpuScalar{0}, GpuScalar{0}, GpuScalar{-9.81}};
    auto constexpr dt = GpuScalar{1e-2};
    auto constexpr substeps   = 1;
    auto constexpr iterations = 10;

    // Act
    using pbat::gpu::vbd::VbdImpl;
    VbdImpl vbd{P, V, F, T};
    vbd.SetExternalAcceleration(aext);
    vbd.SetQuadratureWeights(wg);
    vbd.SetShapeFunctionGradients(GP);
    vbd.SetLameCoefficients(lame);
    vbd.SetVertexTetrahedronAdjacencyList(
        ToEigen(vertexTetrahedronPrefix),
        ToEigen(vertexTetrahedronNeighbours),
        ToEigen(vertexTetrahedronLocalVertexIndices));
    vbd.SetVertexPartitions(partitions);
    vbd.Step(dt, iterations, substeps);

    // Assert
    auto constexpr zero = GpuScalar{1e-4};
    GpuMatrixX dx       = ToEigen(vbd.X.x.Get()).reshaped(P.cols(), P.rows()).transpose() - P;
    bool const bVerticesFallUnderGravity = (dx.row(2).array() < GpuScalar{0}).all();
    CHECK(bVerticesFallUnderGravity);
    bool const bVerticesOnlyFall = (dx.topRows(2).array().abs() < zero).all();
    CHECK(bVerticesOnlyFall);
}
