#include "PPPMTracer.h"
#include <Kernel/TraceHelper.h>
#include <Kernel/TraceAlgorithms.h>
#include <Math/half.h>

namespace CudaTracerLib {

void BeamBeamGrid::StoreBeam(const Beam& b, bool firstStore)
{
	unsigned int beam_idx = atomicInc(&m_uBeamIdx, (unsigned int)-1);
	if (beam_idx < m_uBeamLength)
	{
		m_pDeviceBeams[beam_idx] = b;
		bool storedAll = true;
		//complex variant which pre allocates sufficient storage
		/*Vec3u start_cell = m_sStorage.hashMap.Transform(b.pos);
		unsigned int n_buf_idx = 0;
		for(int i = 0; i < 3; i++)
			n_buf_idx += b.dir[i] < 0 ? start_cell[i] + 1 : m_sStorage.hashMap.m_fGridSize - start_cell[i];
		n_buf_idx = n_buf_idx / 2;
		unsigned int buf_idx = m_sStorage.allocStorage(n_buf_idx), i = 0;
		if(buf_idx >= m_sStorage.numData - n_buf_idx)
		{
			printf("buf_idx = %d, n = %d\n", buf_idx, n_buf_idx);
			return;
		}
#ifdef ISCUDA
		TraverseGrid(Ray(b.pos, b.dir), m_sStorage.hashMap, 0.0f, b.t, [&](float minT, float rayT, float maxT, float cellEndT, Vec3u& cell_pos, bool& cancelTraversal)
		{
			m_sStorage.store(cell_pos, beam_idx, buf_idx + i);
		});
#endif*/
		
#ifdef ISCUDA
		TraverseGrid(Ray(b.pos, b.dir), m_sStorage.hashMap, 0.0f, b.t, [&](float minT, float rayT, float maxT, float cellEndT, Vec3u& cell_pos, bool& cancelTraversal)
		{
			if (!m_sStorage.store(cell_pos, beam_idx))
			{
				storedAll = false;
				cancelTraversal = true;
			}
		});
#endif
		if (firstStore&&storedAll)
			atomicInc(&m_uNumEmitted, (unsigned int)-1);
	}
}

CUDA_CONST unsigned int g_PassIdx;
CUDA_DEVICE unsigned int g_NumPhotonEmitted;
CUDA_DEVICE SpatialLinkedMap<PPPMPhoton> g_SurfaceMap;
CUDA_DEVICE CUDA_ALIGN(16) unsigned char g_VolEstimator[Dmax4(sizeof(PointStorage), sizeof(BeamGrid), sizeof(BeamBeamGrid), sizeof(BeamBVHStorage))];

template<typename VolEstimator> __global__ void k_PhotonPass(int photons_per_thread,  bool DIRECT)
{
	CudaRNG rng = g_RNGData();
	CUDA_SHARED unsigned int local_Counter;
	local_Counter = 0;
	unsigned int local_Todo = photons_per_thread * blockDim.x * blockDim.y;

	DifferentialGeometry dg;
	BSDFSamplingRecord bRec(dg);
	KernelAggregateVolume& V = g_SceneData.m_sVolume;
	CUDA_SHARED unsigned int numStoredSurface;
	numStoredSurface = 0;
	__syncthreads();

	while (atomicInc(&local_Counter, (unsigned int)-1) < local_Todo)// && !g_SurfaceMap.isFull() && !((VolEstimator*)g_VolEstimator)->isFullK()
	{
		Ray r;
		const KernelLight* light;
		Vec2f sps = rng.randomFloat2(), sds = rng.randomFloat2();
		Spectrum Le = g_SceneData.sampleEmitterRay(r, light, sps, sds),
			throughput(1.0f);
		int depth = -1;
		bool wasStoredSurface = false, wasStoredVolume = false;
		bool delta = false;
		MediumSamplingRecord mRec;
		bool medium = false;
		const VolumeRegion* bssrdf = 0;

		while (++depth < PPM_MaxRecursion && !Le.isZero())// && !g_SurfaceMap.isFull() && !((VolEstimator*)g_VolEstimator)->isFullK()
		{
			TraceResult r2 = Traceray(r);
			float minT, maxT;
			if ((!bssrdf && V.HasVolumes() && V.IntersectP(r, 0, r2.m_fDist, &minT, &maxT) && V.sampleDistance(r, 0, r2.m_fDist, rng, mRec))
				|| (bssrdf && bssrdf->sampleDistance(r, 0, r2.m_fDist, rng.randomFloat(), mRec)))
			{
				((VolEstimator*)g_VolEstimator)->StoreBeam(Beam(r.origin, r.direction, mRec.t, throughput * Le), !wasStoredVolume);
				throughput *= mRec.sigmaS * mRec.transmittance / mRec.pdfSuccess;
				((VolEstimator*)g_VolEstimator)->StorePhoton(mRec.p, -r.direction, throughput * Le, !wasStoredVolume);
				wasStoredVolume = true;
				if (bssrdf)
				{
					PhaseFunctionSamplingRecord mRec(-r.direction);
					throughput *= bssrdf->As()->Func.Sample(mRec, rng);
					r.direction = mRec.wi;
				}
				else throughput *= V.Sample(mRec.p, -r.direction, rng, &r.direction);
				r.origin = mRec.p;
				delta = false;
				medium = true;
			}
			else if (!r2.hasHit())
				break;
			else
			{
				if (medium)
					throughput *= mRec.transmittance / mRec.pdfFailure;
				Vec3f wo = bssrdf ? r.direction : -r.direction;
				r2.getBsdfSample(-wo, r(r2.m_fDist), bRec, ETransportMode::EImportance, &rng);
				if ((DIRECT && depth > 0) || !DIRECT)
					if (r2.getMat().bsdf.hasComponent(ESmooth) && dot(bRec.dg.sys.n, wo) > 0.0f)
					{
						auto ph = PPPMPhoton(throughput * Le, wo, bRec.dg.sys.n, delta ? PhotonType::pt_Caustic : PhotonType::pt_Diffuse);
						ph.Pos = dg.P;
						bool b = g_SurfaceMap.store(dg.P, ph);
						if (b && !wasStoredSurface)
							atomicInc(&numStoredSurface, (unsigned int)-1);
						wasStoredSurface = true;
					}
				Spectrum f = r2.getMat().bsdf.sample(bRec, rng.randomFloat2());
				delta = bRec.sampledType & ETypeCombinations::EDelta;
				if (!bssrdf && r2.getMat().GetBSSRDF(bRec.dg, &bssrdf))
					bRec.wo.z *= -1.0f;
				else
				{
					if (!bssrdf)
						throughput *= f;
					bssrdf = 0;
					medium = false;
				}

				r = Ray(bRec.dg.P, bRec.getOutgoing());
			}
		}
	}

	__syncthreads();
	if (threadIdx.x == 0 && threadIdx.y == 0)
		atomicAdd(&g_NumPhotonEmitted, numStoredSurface);

	g_RNGData(rng);
}

void PPPMTracer::doPhotonPass()
{
	m_sSurfaceMap.ResetBuffer();
	m_pVolumeEstimator->StartNewPass(this, m_pScene);
	ThrowCudaErrors(cudaMemcpyToSymbol(g_SurfaceMap, &m_sSurfaceMap, sizeof(m_sSurfaceMap)));
	ZeroSymbol(g_NumPhotonEmitted);
	ThrowCudaErrors(cudaMemcpyToSymbol(g_VolEstimator, m_pVolumeEstimator, m_pVolumeEstimator->getSize()));
	ThrowCudaErrors(cudaMemcpyToSymbol(g_PassIdx, &m_uPassesDone, sizeof(m_uPassesDone)));

	while (!m_sSurfaceMap.isFull() && !m_pVolumeEstimator->isFull())
	{
		if (dynamic_cast<PointStorage*>(m_pVolumeEstimator))
			k_PhotonPass<PointStorage> << < m_uBlocksPerLaunch, dim3(PPM_BlockX, PPM_BlockY, 1) >> >(PPM_Photons_Per_Thread, m_bDirect);
		else if (dynamic_cast<BeamGrid*>(m_pVolumeEstimator))
			k_PhotonPass<BeamGrid> << < m_uBlocksPerLaunch, dim3(PPM_BlockX, PPM_BlockY, 1) >> >(PPM_Photons_Per_Thread, m_bDirect);
		else if (dynamic_cast<BeamBeamGrid*>(m_pVolumeEstimator))
			k_PhotonPass<BeamBeamGrid> << < m_uBlocksPerLaunch, dim3(PPM_BlockX, PPM_BlockY, 1) >> >(PPM_Photons_Per_Thread, m_bDirect);
		else if (dynamic_cast<BeamBVHStorage*>(m_pVolumeEstimator))
			k_PhotonPass<BeamBVHStorage> << < m_uBlocksPerLaunch, dim3(PPM_BlockX, PPM_BlockY, 1) >> >(PPM_Photons_Per_Thread, m_bDirect);
		ThrowCudaErrors(cudaMemcpyFromSymbol(&m_sSurfaceMap, g_SurfaceMap, sizeof(m_sSurfaceMap)));
		ThrowCudaErrors(cudaMemcpyFromSymbol(m_pVolumeEstimator, g_VolEstimator, m_pVolumeEstimator->getSize()));
	}
	ThrowCudaErrors(cudaMemcpyFromSymbol(&m_uPhotonEmittedPass, g_NumPhotonEmitted, sizeof(m_uPhotonEmittedPass)));
	m_pVolumeEstimator->PrepareForRendering();
	m_uPhotonEmittedPass = max(m_uPhotonEmittedPass, m_pVolumeEstimator->getNumEmitted());
	if (m_uTotalPhotonsEmitted == 0)
		doPerPixelRadiusEstimation();
}

}