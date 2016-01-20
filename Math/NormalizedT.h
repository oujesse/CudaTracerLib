#pragma once

#include <Defines.h>

namespace CudaTracerLib {

class IVectorBase;
template<typename T, class Enable = void> struct NormalizedT : public T
{
public:
	CUDA_FUNC_IN explicit NormalizedT(const T& v)
		: T(v)
	{

	}
};

template<typename VEC> struct NormalizedT<VEC, typename std::enable_if<std::is_base_of<IVectorBase, VEC>::value>::type> : public VEC
{
public:
	typedef typename VEC::SCALAR_TYPE  T;
	typedef typename VEC::STORAGE_TYPE S;

	CUDA_FUNC_IN explicit NormalizedT(const VEC& v)
		: VEC(v)
	{

	}

	CUDA_FUNC_IN T lenSqr(void) const = delete;
	CUDA_FUNC_IN T length(void) const = delete;
	CUDA_FUNC_IN S normalized(T len = (T)1) const = delete;
	CUDA_FUNC_IN void normalize(T len = (T)1) = delete;
};

//these static functions will be perfered over the original functions because the template matches better then the base class
template<typename VEC> VEC normalize(const VEC& v)
{
	static_assert(sizeof(VEC) == 0, "normalize is not necessary for normalized vector!");
}

template<typename VEC> typename VEC::SCALAR_TYPE length(const VEC& v)
{
	static_assert(sizeof(VEC) == 0, "length of normalized vector := 1!");
}

template<typename VEC> typename VEC::SCALAR_TYPE lenSqr(const VEC& v)
{
	static_assert(sizeof(VEC) == 0, "lenSqr of normalized vector := 1!");
}

template<typename T> CUDA_FUNC_IN NormalizedT<T> normalized_cast(const T& v)
{
	return NormalizedT<T>(v);
}

}