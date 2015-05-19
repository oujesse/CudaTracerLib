#pragma once

#include "..\MathTypes.h"
#include "k_BlockSampler_device.h"

struct k_SamplerpixelData
{
	float E, E2;
	float lastVar;
	unsigned int n;
	unsigned int flag;
};

class k_BlockSampler : public IBlockSampler
{
	k_SamplerpixelData* m_pLumData;
	e_Image* img;

	unsigned int m_uPassesDone;
	unsigned int* m_pDeviceIndexData;
	float* m_pDeviceBlockData;
	float* m_pHostBlockData;
	unsigned int* m_pHostIndexData;
	unsigned int m_uNumBlocksToLaunch;
	bool hasValidData;
	unsigned int* m_pDeviceSamplesData;
	unsigned int* m_pHostSamplesData;
	unsigned int* m_pDeviceContribPixels;
	unsigned int* m_pHostContribPixels;
	float* m_pHostWeight;
	float* m_pDeviceWeight;
public:
	k_BlockSampler(e_Image* img)
		: img(img)
	{
		unsigned int nBlocks = totalNumBlocks();
		CUDA_MALLOC(&m_pLumData, img->getWidth() * img->getHeight() * sizeof(k_SamplerpixelData));
		CUDA_MALLOC(&m_pDeviceBlockData, nBlocks * sizeof(float));
		CUDA_MALLOC(&m_pDeviceIndexData, nBlocks * sizeof(unsigned int));
		CUDA_MALLOC(&m_pDeviceSamplesData, nBlocks * sizeof(unsigned int));
		CUDA_MALLOC(&m_pDeviceContribPixels, nBlocks * sizeof(unsigned int));
		CUDA_MALLOC(&m_pDeviceWeight, nBlocks * sizeof(float));
		m_pHostIndexData = new unsigned int[nBlocks];
		m_pHostBlockData = new float[nBlocks];
		m_pHostSamplesData = new unsigned int[nBlocks];
		m_pHostContribPixels = new unsigned int[nBlocks];
		m_pHostWeight = new float[nBlocks];
		Clear();
		for (unsigned int i = 0; i < nBlocks; i++)
			m_pHostWeight[i] = 1;
	}
	virtual ~k_BlockSampler()
	{
		Free();
	}
	virtual void Free()
	{
		CUDA_FREE(m_pLumData);
		CUDA_FREE(m_pDeviceIndexData);
		CUDA_FREE(m_pDeviceBlockData);
		CUDA_FREE(m_pDeviceSamplesData);
		CUDA_FREE(m_pDeviceContribPixels);
		CUDA_FREE(m_pDeviceWeight);
		delete[] m_pHostIndexData;
		delete[] m_pHostBlockData;
		delete[] m_pHostSamplesData;
		delete[] m_pHostContribPixels;
		delete[] m_pHostWeight;
	}
	float getBlockVariance(int idx) const
	{
		return m_pHostBlockData[idx];
	}
	virtual void AddPass();
	virtual void Clear();
	virtual unsigned int NumBlocks() const
	{
		if (hasValidData)
			return m_uNumBlocksToLaunch;
		else return totalNumBlocks();
	}
	unsigned int totalNumBlocks() const
	{
		return ((img->getWidth() + blockSize - 1) / blockSize) * ((img->getHeight() + blockSize - 1) / blockSize);
	}
	unsigned int numBlocksRow() const
	{
		return (img->getWidth() + blockSize - 1) / blockSize;
	}
	virtual void getBlockCoords(unsigned int idx, unsigned int& x, unsigned int& y, unsigned int& w, unsigned int& h, bool ignoreData = false) const
	{
		if (hasValidData && !ignoreData)
			idx = m_pHostIndexData[idx];
		unsigned int ix = idx % numBlocksRow();
		unsigned int iy = idx / numBlocksRow();
		x = ix * blockSize;
		y = iy * blockSize;
		unsigned int x2 = (ix + 1) * blockSize, y2 = (iy + 1) * blockSize;
		w = min(img->getWidth(), x2) - x;
		h = min(img->getHeight(), y2) - y;
	}
	unsigned int mapIdx(unsigned int idx) const
	{
		return hasValidData ? m_pHostIndexData[idx] : idx;
	}

	virtual k_BlockSampleImage getBlockImage() const
	{
		return k_BlockSampleImage(img, m_pLumData);
	}
	void DrawVariance(bool blocks) const;
	unsigned int* getNumSamplesPerBlock() const
	{
		return m_pHostSamplesData;
	}
	float& accessWeight(unsigned int idx)
	{
		return m_pHostWeight[idx];
	}
};