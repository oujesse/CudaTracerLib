#include "k_sPpmTracer.h"
#include "k_TraceHelper.h"

CUDA_DEVICE k_PhotonMapCollection g_Map;

template<bool DIRECT> CUDA_FUNC_IN bool TracePhoton(Ray& r, Spectrum Le, CudaRNG& rng)
{
	r.direction = normalize(r.direction);
	e_KernelAggregateVolume& V = g_SceneData.m_sVolume;
	TraceResult r2;
	r2.Init();
	int depth = -1;
	//bool inMesh = false;
	BSDFSamplingRecord bRec;
	while(++depth < 7 && k_TraceRay(r.direction, r.origin, &r2))
	{
		if(V.HasVolumes())
		{
			float minT, maxT;
			while(V.IntersectP(r, 0, r2.m_fDist, &minT, &maxT))
			{
				float3 x = r(minT), w = -r.direction;
				Spectrum sigma_s = V.sigma_s(x, w), sigma_t = V.sigma_t(x, w);
				float d = -logf(rng.randomFloat()) / sigma_t.average();
				bool cancel = d >= (maxT - minT) || d >= r2.m_fDist;
				d = clamp(d, minT, maxT);
				Le += V.Lve(x, w) * d;
				if(g_Map.StorePhoton<false>(r(minT + d * rng.randomFloat()), Le, w, make_float3(0,0,0)) == k_StoreResult::Full)
					return false;
				if(cancel)
					break;
				float A = (sigma_s / sigma_t).average();
				if(rng.randomFloat() <= A)
				{
					float3 wi;
					float pf = V.Sample(x, -r.direction, rng, &wi);
					Le /= A;
					Le *= pf;
					r.origin = r(minT + d);
					r.direction = wi;
					r2.Init();
					if(!k_TraceRay(r.direction, r.origin, &r2))
						return true;
				}
				else break;//Absorption
			}
		}
		float3 x = r(r2.m_fDist);
		r2.getBsdfSample(r, rng, &bRec);
		const e_KernelBSSRDF* bssrdf;
		Spectrum ac;
		if(r2.getMat().GetBSSRDF(bRec.map, &bssrdf))
		{
			//inMesh = false;
			ac = Le;
			Ray br = BSSRDF_Entry(bssrdf, bRec.map.sys, x, r.direction);
			while(true)
			{
				TraceResult r3 = k_TraceRay(br);
				Spectrum sigma_s = bssrdf->sigp_s, sigma_t = bssrdf->sigp_s + bssrdf->sig_a;
				float d = -logf(rng.randomFloat()) / sigma_t.average();
				bool cancel = d >= (r3.m_fDist);
				d = clamp(d, 0.0f, r3.m_fDist);
				if(g_Map.StorePhoton<false>(br(d * rng.randomFloat()), ac, -br.direction, make_float3(0,0,0)) == k_StoreResult::Full)
					return false;
				if(cancel)
				{
					Frame sys;
					r3.lerpFrame(sys);
					x = br(r3.m_fDist);//point on a surface
					Ray out = BSSRDF_Exit(bssrdf, sys, x, br.direction);
					bRec.wo = bRec.map.sys.toLocal(out.direction);//ugly
					break;
				}
				float A = (sigma_s / sigma_t).average();
				if(rng.randomFloat() <= A)
				{
					ac /= A;
					float3 wo = Warp::squareToUniformSphere(rng.randomFloat2());
					ac *= 1.f / (4.f * PI);
					br = Ray(br(d), wo);
				}
				else return true;
			}
		}
		else
		{
			float3 wo = -r.direction;
			if((DIRECT && depth > 0) || !DIRECT)
				if(r2.getMat().bsdf.hasComponent(EDiffuse))
					if(g_Map.StorePhoton<true>(x, Le, wo, bRec.map.sys.n) == k_StoreResult::Full)
						return false;
			Spectrum f = r2.getMat().bsdf.sample(bRec, rng.randomFloat2());
			if(!bRec.sampledType)
				break;
			//inMesh = dot(r.direction, bRec.map.sys.n) < 0;
			ac = Le * f;
		}
		if(depth > 1)
		{
			float prob = MIN(1.0f, ac.max() / Le.max());
			if(rng.randomFloat() > prob)
				break;
			Le = ac / prob;
		}
		else Le = ac;
		r = Ray(x, bRec.getOutgoing());
		r2.Init();
	}
	return true;
}

template<bool DIRECT, int SPP> __global__ void k_PhotonPass()
{ 
	CudaRNG rng = g_RNGData();
	for(int _photonNum = 0; _photonNum < SPP; _photonNum++)
	{
		Ray photonRay;
		const e_KernelLight* light;
		Spectrum Le = g_SceneData.sampleEmitterRay(photonRay, light, rng.randomFloat2(), rng.randomFloat2());
		if(Le.isZero())
			continue;
		if(TracePhoton<DIRECT>(photonRay, Le, rng))
			atomicInc(&g_Map.m_uPhotonNumEmitted, 0xffffffff);
		else break;
	}
	g_RNGData(rng);
}

void k_sPpmTracer::doPhotonPass()
{
	cudaMemcpyToSymbol(g_Map, &m_sMaps, sizeof(k_PhotonMapCollection));
	k_INITIALIZE(m_pScene->getKernelSceneData());
	k_STARTPASS(m_pScene, m_pCamera, g_sRngs);
	const unsigned long long p0 = 6 * 32, spp = 1, n = 180;
	if(m_bDirect)
		k_PhotonPass<true, spp><<< n, p0 >>>();
	else k_PhotonPass<false, spp><<< n, p0 >>>();
	cudaThreadSynchronize();
	cudaMemcpyFromSymbol(&m_sMaps, g_Map, sizeof(k_PhotonMapCollection));
}