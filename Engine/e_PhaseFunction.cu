#include "e_PhaseFunction.h"

float e_HGPhaseFunction::Evaluate(const PhaseFunctionSamplingRecord &pRec) const
{
	float temp = 1.0f + m_g*m_g + 2.0f * m_g * dot(pRec.wi, pRec.wo);
	return (1.0f / (4.0f * PI)) * (1 - m_g*m_g) / (temp * sqrtf(temp));
}

float e_HGPhaseFunction::Sample(PhaseFunctionSamplingRecord &pRec, CudaRNG& sampler) const
{
	float2 sample = sampler.randomFloat2();

	float cosTheta;
	if (std::abs(m_g) < EPSILON)
	{
		cosTheta = 1 - 2*sample.x;
	}
	else
	{
		float sqrTerm = (1 - m_g * m_g) / (1 - m_g + 2 * m_g * sample.x);
		cosTheta = (1 + m_g * m_g - sqrTerm * sqrTerm) / (2 * m_g);
	}

	float sinTheta = sqrtf(1.0f-cosTheta*cosTheta), sinPhi, cosPhi;

	sincos(2*PI*sample.y, &sinPhi, &cosPhi);

	pRec.wo = Frame(-pRec.wi).toWorld(make_float3(
		sinTheta * cosPhi,
		sinTheta * sinPhi,
		cosTheta
	));

	return 1.0f;
}

float e_HGPhaseFunction::Sample(PhaseFunctionSamplingRecord &pRec, float &pdf, CudaRNG& sampler) const
{
	e_HGPhaseFunction::Sample(pRec, sampler);
	pdf = e_HGPhaseFunction::Evaluate(pRec);
	return 1.0f;
}

float e_IsotropicPhaseFunction::Evaluate(const PhaseFunctionSamplingRecord &pRec) const
{
	return Warp::squareToUniformSpherePdf();
}

float e_IsotropicPhaseFunction::Sample(PhaseFunctionSamplingRecord &pRec, CudaRNG& sampler) const
{
	float2 sample = sampler.randomFloat2();
	pRec.wo = Warp::squareToUniformSphere(sample);
	return 1.0f;
}

float e_IsotropicPhaseFunction::Sample(PhaseFunctionSamplingRecord &pRec, float &pdf, CudaRNG& sampler) const
{
	pRec.wo = Warp::squareToUniformSphere(sampler.randomFloat2());
	pdf = Warp::squareToUniformSpherePdf();
	return 1.0f;
}

e_KajiyaKayPhaseFunction::e_KajiyaKayPhaseFunction(float ks, float kd, float e, float3 o)
	: e_BasePhaseFunction(EPhaseFunctionType::pEAnisotropic), m_ks(ks), m_kd(kd), m_exponent(e), orientation(o)
{
	int nParts = 1000;
	float stepSize = PI / nParts, m=4, theta = stepSize;

	m_normalization = 0; /* 0 at the endpoints */
	for (int i=1; i<nParts; ++i) {
		float value = powf(cosf(theta - PI/2), m_exponent)
			* sinf(theta);
		m_normalization += value * m;
		theta += stepSize;
		m = 6-m;
	}

	m_normalization = 1/(m_normalization * stepSize/3 * 2 * PI);
}

float e_KajiyaKayPhaseFunction::Evaluate(const PhaseFunctionSamplingRecord &pRec) const
{
	if (length(orientation) == 0)
		return m_kd / (4*PI);

	Frame frame(normalize(orientation));
	float3 reflectedLocal = frame.toLocal(pRec.wo);

	reflectedLocal.z = -dot(pRec.wi, frame.n);
	float a = sqrtf((1-reflectedLocal.z*reflectedLocal.z) / (reflectedLocal.x*reflectedLocal.x + reflectedLocal.y*reflectedLocal.y));
	reflectedLocal.y *= a;
	reflectedLocal.x *= a;
	float3 R = frame.toWorld(reflectedLocal);

	return powf(MAX(0.0f, dot(R, pRec.wo)), m_exponent) * m_normalization * m_ks + m_kd / (4*PI);
}

float e_KajiyaKayPhaseFunction::Sample(PhaseFunctionSamplingRecord &pRec, CudaRNG& sampler) const
{
	pRec.wo = Warp::squareToUniformSphere(sampler.randomFloat2());
	return Evaluate(pRec) * (4 * PI);
}

float e_KajiyaKayPhaseFunction::Sample(PhaseFunctionSamplingRecord &pRec, float &pdf, CudaRNG& sampler) const
{
	pRec.wo = Warp::squareToUniformSphere(sampler.randomFloat2());
	pdf = Warp::squareToUniformSpherePdf();
	return Evaluate(pRec) * (4 * PI);
}

float e_RayleighPhaseFunction::Evaluate(const PhaseFunctionSamplingRecord &pRec) const
{
	float mu = dot(pRec.wi, pRec.wo);
	return (3.0f/(16.0f*PI)) * (1+mu*mu);
}

float e_RayleighPhaseFunction::Sample(PhaseFunctionSamplingRecord &pRec, CudaRNG& sampler) const
{
	float2 sample(sampler.randomFloat2());

	float z = 2 * (2*sample.x - 1),
			tmp = sqrtf(z*z+1),
			A = powf(z+tmp, (float) (1.0f/3.0f)),
			B = powf(z-tmp, (float) (1.0f/3.0f)),
			cosTheta = A + B,
			sinTheta = sqrtf(1.0f-cosTheta*cosTheta),
			phi = 2*PI*sample.y, cosPhi, sinPhi;
	sincos(phi, &sinPhi, &cosPhi);

	float3 dir = make_float3(
		sinTheta * cosPhi,
		sinTheta * sinPhi,
		cosTheta);

	pRec.wo = Frame(-pRec.wi).toWorld(dir);
	return 1.0f;
}

float e_RayleighPhaseFunction::Sample(PhaseFunctionSamplingRecord &pRec, float &pdf, CudaRNG& sampler) const
{
	e_RayleighPhaseFunction::Sample(pRec, sampler);
	pdf = e_RayleighPhaseFunction::Evaluate(pRec);
	return 1.0f;
}