#ifndef PBAT_FEM_SHAPE_FUNCTIONS_H
#define PBAT_FEM_SHAPE_FUNCTIONS_H

#include "Concepts.h"
#include "Jacobian.h"

#include <Eigen/SVD>
#include <exception>
#include <fmt/core.h>
#include <pbat/Aliases.h>
#include <pbat/profiling/Profiling.h>
#include <string>
#include <tbb/parallel_for.h>

namespace pbat {
namespace fem {

/**
 * @brief Computes shape functions at element quadrature points for a polynomial quadrature rule of
 * order QuadratureOrder
 * @tparam TElement
 * @tparam QuadratureOrder
 * @return The shape function values of each node at quadrature points, stored in a matrix
 * of dimensions |#element nodes| x |#quad.pts.|
 */
template <CElement TElement, int QuadratureOrder>
Matrix<TElement::kNodes, TElement::template QuadratureType<QuadratureOrder>::kPoints>
ShapeFunctions()
{
    using QuadratureRuleType = typename TElement::template QuadratureType<QuadratureOrder>;
    using ElementType        = TElement;
    auto const Xg            = common::ToEigen(QuadratureRuleType::points)
                        .reshaped(QuadratureRuleType::kDims + 1, QuadratureRuleType::kPoints)
                        .template bottomRows<QuadratureRuleType::kDims>();
    Matrix<ElementType::kNodes, QuadratureRuleType::kPoints> Ng{};
    for (auto g = 0; g < QuadratureRuleType::kPoints; ++g)
    {
        Ng.col(g) = ElementType::N(Xg.col(g));
    }
    return Ng;
}

template <CElement TElement, class TDerivedXi>
MatrixX ShapeFunctionsAt(Eigen::DenseBase<TDerivedXi> const& Xi)
{
    PBAT_PROFILE_NAMED_SCOPE("fem.ShapeFunctionsAt");
    using ElementType = TElement;
    if (Xi.rows() != ElementType::kDims)
    {
        std::string const what = fmt::format(
            "Expected evaluation points in d={} dimensions, but got Xi.rows()={}",
            ElementType::kDims,
            Xi.rows());
        throw std::invalid_argument(what);
    }
    MatrixX N(ElementType::kNodes, Xi.cols());
    tbb::parallel_for(Index{0}, Index{Xi.cols()}, [&](Index i) {
        N.col(i) = ElementType::N(Xi.col(i));
    });
    return N;
}

/**
 * @brief Integrate shape functions on each element
 * @tparam TDerived
 * @tparam TMesh
 * @tparam QuadratureOrder
 * @param mesh
 * @param detJe
 * @return |#element nodes|x|#elements|
 */
template <int QuadratureOrder, CMesh TMesh, class TDerived>
MatrixX IntegratedShapeFunctions(TMesh const& mesh, Eigen::DenseBase<TDerived> const& detJe)
{
    PBAT_PROFILE_NAMED_SCOPE("fem.IntegratedShapeFunctions");
    using MeshType           = TMesh;
    using ElementType        = typename MeshType::ElementType;
    using QuadratureRuleType = typename ElementType::template QuadratureType<QuadratureOrder>;
    auto constexpr kQuadPts  = QuadratureRuleType::kPoints;
    auto constexpr kQuadratureOrder = QuadratureOrder;
    auto const numberOfElements     = mesh.E.cols();
    bool const bHasDeterminants = (detJe.rows() == kQuadPts) and (detJe.cols() == numberOfElements);
    if (not bHasDeterminants)
    {
        std::string const what = fmt::format(
            "Expected element jacobian determinants of dimensions {}x{} for element quadrature of "
            "order={}, but got {}x{}",
            kQuadPts,
            numberOfElements,
            kQuadratureOrder,
            detJe.rows(),
            detJe.cols());
        throw std::invalid_argument(what);
    }
    // Precompute element shape functions
    auto constexpr kNodesPerElement             = ElementType::kNodes;
    Matrix<kNodesPerElement, kQuadPts> const Ng = ShapeFunctions<ElementType, kQuadratureOrder>();
    // Integrate shape functions
    MatrixX N     = MatrixX::Zero(kNodesPerElement, numberOfElements);
    auto const wg = common::ToEigen(QuadratureRuleType::weights);
    tbb::parallel_for(Index{0}, Index{numberOfElements}, [&](Index e) {
        for (auto g = 0; g < QuadratureRuleType::kPoints; ++g)
        {
            N.col(e) += (wg(g) * detJe(g, e)) * Ng.col(g);
        }
    });
    return N;
}

/**
 * @brief Computes gradients of FEM basis functions in reference element. Only works for linear
 * maps, but we do not emit an error when TElement::bHasConstantJacobian is false, since the
 * element's function space might be non-linear, while its current configuration induces a linear
 * map. I.e., a kth order element that is purely a rigid transformation on the reference element
 * still induces a linear map, even if the element's function space is kth order. It is up to the
 * user to give the right inputs, and we cannot/won't check those.
 *
 * @tparam TDerivedXi
 * @tparam TDerivedX
 * @tparam TElement
 * @param Xi Point in reference element at which to evaluate the gradients
 * @param X Element vertices, i.e. nodes of affine element
 * @return |#nodes|x|Dims| matrix of basis function gradients in rows
 */
template <CElement TElement, class TDerivedXi, class TDerivedX>
Matrix<TElement::kNodes, TDerivedX::RowsAtCompileTime> ShapeFunctionGradients(
    Eigen::MatrixBase<TDerivedXi> const& Xi,
    Eigen::MatrixBase<TDerivedX> const& X)
{
    // NOTE:
    // \phi(X) = N(\Xi(X))
    // So to be mathematically precise, what we should compute is:
    // -> \nabla \phi(X) = \nabla \Xi N(\Xi(X)) J_X \Xi(X)
    // ->                = grad N * J_X \Xi(X)
    // This requires the Jacobian of the inverse map taking domain element to reference element.
    // Because this map is potentially non-linear, we compute it via Gauss-Newton iterations in
    // Jacobian.h. Hence, to get the jacobian of that map, we also need to compute derivatives of
    // the Gauss-Newton iterations in Jacobian.h.
    //
    // However, we assume that domain elements are linear transformations of reference elements,
    // so that the inverse map is linear, i.e. the Jacobian is constant. Hence,
    // \phi(X) = N(J^{-1} (X - X_0)) = N(\Xi)
    // grad_X \phi(X) = d N(\Xi) / d\Xi d \Xi / dX
    //                = grad_\Xi N * J^{-1}
    // If we transpose that equation, we get
    // [ grad_X \phi(X) ]^T = J^{-T} * grad_\Xi N^T
    // Recall that the pseudoinverse of J is J^{-1} = U \Sigma^{-1} V^T
    // We pseudoinvert its transpose directly, J^{-T} = V \Sigma^{-1} U^T
    //
    // For non-linear elements, like hexahedra or quadrilaterals, the accuracy of the gradients
    // might be unacceptable, but will be exact, if domain hex or quad elements are linear
    // transformations on reference hex/quad elements. This is the case for axis-aligned elements,
    // for example, which would arise when constructing a mesh from an octree or quadtree.
    auto constexpr kInputDims                = TElement::kDims;
    auto constexpr kOutputDims               = TDerivedX::RowsAtCompileTime;
    using AffineElementType                  = typename TElement::AffineBaseType;
    Matrix<kInputDims, kOutputDims> const JT = (X * AffineElementType::GradN(Xi)).transpose();
    int constexpr kComputationOptions        = []() {
        // TDerivedX::RowsAtCompileTime being dynamic means that JT has a dynamic number of columns.
        // ThinU and ThinV SVD options are only supported when input matrix is dynamic (in
        // #columns).
        if constexpr (TDerivedX::RowsAtCompileTime == Eigen::Dynamic)
            return Eigen::ComputeThinU | Eigen::ComputeThinV;
        else
            return Eigen::ComputeFullU | Eigen::ComputeFullV;
    }();
    auto const JinvT                               = JT.jacobiSvd(kComputationOptions);
    Matrix<kInputDims, TElement::kNodes> const GNT = TElement::GradN(Xi).transpose();
    Matrix<TElement::kNodes, kOutputDims> GP;
    // Would like to write
    // GP.transpose() = JinvT.solve(GNT);
    // but apparently SVD solver only solves for vectors.
    for (auto i = 0; i < TElement::kNodes; ++i)
        GP.row(i).transpose() = JinvT.solve(GNT.col(i));
    return GP;
}

/**
 * @brief Computes nodal shape function gradients at each element quadrature point.
 * @tparam Order
 * @tparam TMesh
 * @param mesh
 * @return |#element nodes| x |#dims * #quad.pts. * #elements| matrix of shape functions
 */
template <int QuadratureOrder, CMesh TMesh>
MatrixX ShapeFunctionGradients(TMesh const& mesh)
{
    PBAT_PROFILE_NAMED_SCOPE("fem.ShapeFunctionGradients");
    using MeshType              = TMesh;
    using ElementType           = typename MeshType::ElementType;
    using QuadratureRuleType    = typename ElementType::template QuadratureType<QuadratureOrder>;
    using AffineElementType     = typename ElementType::AffineBaseType;
    auto const numberOfElements = mesh.E.cols();
    auto constexpr kNodesPerElement = ElementType::kNodes;
    auto const Xg                   = common::ToEigen(QuadratureRuleType::points)
                        .reshaped(QuadratureRuleType::kDims + 1, QuadratureRuleType::kPoints)
                        .template bottomRows<ElementType::kDims>();
    MatrixX GNe(kNodesPerElement, numberOfElements * MeshType::kDims * QuadratureRuleType::kPoints);
    tbb::parallel_for(Index{0}, Index{numberOfElements}, [&](Index e) {
        auto const nodes                = mesh.E.col(e);
        auto const vertices             = nodes(ElementType::Vertices);
        auto constexpr kRowsJ           = MeshType::kDims;
        auto constexpr kColsJ           = AffineElementType::kNodes;
        Matrix<kRowsJ, kColsJ> const Ve = mesh.X(Eigen::all, vertices);
        for (auto g = 0; g < QuadratureRuleType::kPoints; ++g)
        {
            auto const GP          = ShapeFunctionGradients<ElementType>(Xg.col(g), Ve);
            auto constexpr kStride = MeshType::kDims * QuadratureRuleType::kPoints;
            GNe.block<kNodesPerElement, MeshType::kDims>(0, e * kStride + g * MeshType::kDims) = GP;
        }
    });
    return GNe;
}

} // namespace fem
} // namespace pbat

#endif // PBAT_FEM_SHAPE_FUNCTIONS_H
