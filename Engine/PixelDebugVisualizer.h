#pragma once

#include <map>
#include <string>
#include "SynchronizedBuffer.h"
#include <Math/Vector.h>
#include <Math/Spectrum.h>

namespace CudaTracerLib {

class Image;

class IDebugDrawer
{
public:
	virtual void DrawLine(const Vec3f& p1, const Vec3f& p2, const Spectrum& col) const = 0;
	virtual void DrawEllipsisOnSurface(const Vec3f& p1, const NormalizedT<Vec3f>& t1, const NormalizedT<Vec3f>& t2, float l1, float l2) const = 0;
	virtual void DrawEllipsoidOnSurface(const Vec3f& p1, const NormalizedT<Vec3f>& t1, const NormalizedT<Vec3f>& t2, const NormalizedT<Vec3f>& n, float l1, float l2, float l3) const = 0;
};

class IPixelDebugVisualizer
{
protected:
	std::string m_name;
	IPixelDebugVisualizer(const std::string& name)
		: m_name(name)
	{

	}
public:
	virtual ~IPixelDebugVisualizer()
	{

	}
	virtual void Free() = 0;
	virtual void Visualize(Image& img) = 0;
	virtual void VisualizePixel(const IDebugDrawer& drawer) = 0;
	virtual void Resize(unsigned int w, unsigned int h) = 0;
	virtual const std::string& getName() const
	{
		return m_name;
	}

	enum class FeatureVisualizer
	{
		Vertex,
		Edge,
	};
	virtual void VisualizeFeatures(const IDebugDrawer& drawer, FeatureVisualizer features);
};

template<typename T> class PixelDebugVisualizerBase : public IPixelDebugVisualizer, public ISynchronizedBufferParent
{
protected:
	float m_uniform_scale;
	unsigned int m_width;
	SynchronizedBuffer<T> m_buffer;
	PixelDebugVisualizerBase(const std::string& name)
		: IPixelDebugVisualizer(name), ISynchronizedBufferParent(m_buffer), m_buffer(1), m_uniform_scale(1)
	{

	}

public:
	virtual void Free()
	{
		m_buffer.Free();
	}

	virtual void Resize(unsigned int w, unsigned int h)
	{
		m_width = w;
		m_buffer.Resize(w * h);
	}

	CUDA_FUNC_IN T& operator()(unsigned int x, unsigned int y)
	{
		return m_buffer[y * m_width + x];
	}

	CUDA_FUNC_IN const T& operator()(unsigned int x, unsigned int y) const
	{
		return m_buffer[y * m_width + x];
	}

	CUDA_FUNC_IN T getScaledValue(unsigned int x, unsigned int y) const
	{
		return operator()(x, y) * m_uniform_scale;
	}

	void setScale(float f)
	{
		m_uniform_scale = f;
	}
};

template<typename T> class PixelDebugVisualizer : public PixelDebugVisualizerBase<T>
{
};

template<> class PixelDebugVisualizer<float> : public PixelDebugVisualizerBase<float>
{
public:
	//linear normalization from [a,b] -> [0, 1]
	bool m_normalize;
	enum class VisualizePixelType
	{
		Circle,
		//visualizes the value as scaled normal
		Normal,
	};
	VisualizePixelType m_pixelType;
public:
	PixelDebugVisualizer(const std::string& name)
		: PixelDebugVisualizerBase(name), m_normalize(true), m_pixelType(VisualizePixelType::Circle)
	{

	}

	virtual void Visualize(Image& img);
	virtual void VisualizePixel(const IDebugDrawer& drawer);
};

template<> class PixelDebugVisualizer<Vec2f> : public PixelDebugVisualizerBase<Vec2f>
{
public:
	//linear normalization from [-1,1] -> [0, 1]
	bool m_normalize;
	enum class VisualizePixelType
	{
		Ellipse,
		//visualizes the value as element of the tangent plane
		OnSurface,
	};
	VisualizePixelType m_pixelType;
public:
	PixelDebugVisualizer(const std::string& name)
		: PixelDebugVisualizerBase(name), m_normalize(false), m_pixelType(VisualizePixelType::Ellipse)
	{

	}

	virtual void Visualize(Image& img);
	virtual void VisualizePixel(const IDebugDrawer& drawer);
};

template<> class PixelDebugVisualizer<Vec3f> : public PixelDebugVisualizerBase<Vec3f>
{
public:
	//linear normalization from [-1,1] -> [0, 1]
	bool m_normalize;
	enum class VisualizePixelType
	{
		Elipsoid,
		//visualizes the value as element of the orthonormal surface base
		OnSurface,
	};
	VisualizePixelType m_pixelType;
public:
	PixelDebugVisualizer(const std::string& name)
		: PixelDebugVisualizerBase(name), m_normalize(false), m_pixelType(VisualizePixelType::Elipsoid)
	{

	}

	virtual void Visualize(Image& img);
	virtual void VisualizePixel(const IDebugDrawer& drawer);
};

class PixelDebugVisualizerManager
{
	std::map<std::string, IPixelDebugVisualizer*> m_visualizers;
	unsigned int m_width, m_height;
public:
	template<typename T> PixelDebugVisualizer<T>& findOrCreate(const std::string& name)
	{
		auto it = m_visualizers.find(name);
		auto* ptr = dynamic_cast<PixelDebugVisualizer<T>*>(it->second);
		if (it != m_visualizers.end() && ptr)
			return *ptr;

		ptr = new PixelDebugVisualizer<T>(name);
		ptr->Resize(m_width, m_height);
		m_visualizers[name] = ptr;
		return ptr;
	}

	void Resize(unsigned int w, unsigned int h)
	{
		m_width = w;
		m_height = h;
		for (auto ent : m_visualizers)
			ent.second->Resize(w, h);
	}

	void Free()
	{
		for (auto ent : m_visualizers)
			delete ent.second;
	}
};

}