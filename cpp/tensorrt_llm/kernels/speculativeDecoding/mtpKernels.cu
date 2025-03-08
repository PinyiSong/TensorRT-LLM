/*
 * Copyright (c) 2019-2024, NVIDIA CORPORATION.  All rights reserved.
 * Copyright (c) 2021, NAVER Corp.  Authored by CLOVA.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <cuda_runtime_api.h>

#include <cuda_bf16.h>
#include <cuda_fp16.h>

#ifdef ENABLE_FP8
#include <cuda_fp8.h>
#endif

#include "mtpKernels.h"
#include "tensorrt_llm/common/assert.h"
#include "tensorrt_llm/common/cudaBf16Fallbacks.cuh"
#include "tensorrt_llm/common/cudaTypeUtils.cuh"

using namespace tensorrt_llm::common;

namespace tensorrt_llm
{
namespace kernels
{

template <typename T>
__device__ void copyChunkedHiddenStates(T const* srcPtr, T* dstPtr, int const numElement)
{
    if (numElement <= 0)
    {
        return;
    }
    else
    {
        int const tid = static_cast<int>(threadIdx.x);
        int const stride = static_cast<int>(blockDim.x);

        auto srcPtr16B = reinterpret_cast<float4 const*>(srcPtr);
        auto dstPtr16B = reinterpret_cast<float4*>(dstPtr);

        int ii = tid;
        int maxIdx = numElement * sizeof(T) / sizeof(float4);

        while (ii < maxIdx)
        {
            dstPtr16B[ii] = srcPtr16B[ii];
            ii += stride;
        }
    }
}

template <typename T>
__global__ void mtpPrepareDrafterInputsKernel(int const numMTPModules, int const curMTPLayerIdx, int const batchSize,
    int const numContextRequest, int const hiddenSize, int const* inputIds, int const* seqLens,
    T** const mtpPastHiddenStatesPtrs, int** const mtpPastTokensPtrs, T* const previousLayerHiddenStates,
    int* const previousLayerDraftTokens, int* returnInputIds, T* returnHiddenStates)
{
    /*
        In a batch of request: context request (at the beginning) + generation requests
        numGenerationRequest = batchSize - numContextRequest

        inputIds: [N]
            - When curMTPLayerIdx == 0: N = sum(all numContextRequest's prompts) + numGenerationRequest * (numMTPModules
       + 1)
            - When curMTPLayerIdx > 0:  N = sum(all numContextRequest's prompts) + numGenerationRequest * numMTPModules
        seqLens: [batchSize]
        mtpPastHiddenStatesPtrs: [maxNumRequests][numMTPModules, hiddenSize]
        mtpPastTokensPtrs: [maxNumRequests][numMTPModules]
        previousLayerHiddenStates: [N, hiddenSize]
            - When curMTPLayerIdx == 0: N = sum(all numContextRequest's prompts) + numGenerationRequest * (numMTPModules
       + 1) (from target model)
            - When curMTPLayerIdx > 0:  N = sum(all numContextRequest's prompts) + numGenerationRequest * numMTPModules
        previousLayerDraftTokens: [batchSize], the draft tokens generated by the previous layer
        returnInputIds: [N]
            - N = sum(all numContextRequest's prompts) + numGenerationRequest * numMTPModules
        returnHiddenStates: [N, hiddenSize]
    */

    int const bid = static_cast<int>(blockIdx.x); // Each block is responsible for a request.
    int const tid = static_cast<int>(threadIdx.x);

    T const* curMTPPastHiddenStatesPtr = mtpPastHiddenStatesPtrs[bid];
    int const* curMTPPastTokensPtr = mtpPastTokensPtrs[bid];

    int curSeqLen = seqLens[bid];

    int inputIdsStartOffset = 0;       // The start index of the inputIds
    int returnInputIdsStartOffset = 0; // The start index of the write back returnInputIds
    // TODO: better to optimize
    for (int i = 0; i < bid; i++)
    {
        inputIdsStartOffset += seqLens[i];

        if (i < numContextRequest)
        {
            // For the context requests, we will copy 'prompt length' tokens
            returnInputIdsStartOffset += seqLens[i];
        }
        else
        {
            // For the generation requests, we will copy 'numMTPModules' tokens
            returnInputIdsStartOffset += numMTPModules;
        }
    }

    int const* curInputIdsPtr = inputIds + inputIdsStartOffset;
    T const* curPreviousLayerHiddenStates = previousLayerHiddenStates + inputIdsStartOffset * hiddenSize;

    int* curReturnInputIdsPtr = returnInputIds + returnInputIdsStartOffset;
    T* curReturnHiddenStatesIdsPtr = returnHiddenStates + returnInputIdsStartOffset * hiddenSize;

    //// main logic

    if (curMTPLayerIdx == 0)
    {
        if (bid < numContextRequest)
        {
            // context requests
            if (tid == 0)
            {
                // 1) For the new inputIds
                for (int ii = 0; ii < curSeqLen - 1; ii++)
                {
                    curReturnInputIdsPtr[ii] = curInputIdsPtr[ii + 1]; // +1 because of offset 1, prompt[1:]
                }
                // Append the latest golden token, i.e., the last one in the past tokens list
                curReturnInputIdsPtr[curSeqLen - 1] = curMTPPastTokensPtr[numMTPModules - 1];
            }

            // 2) For the new past hidden states
            copyChunkedHiddenStates(curPreviousLayerHiddenStates, curReturnHiddenStatesIdsPtr, curSeqLen * hiddenSize);
        }
        else
        {
            // generation requests
            if (tid == 0)
            {
                // 1) For the new inputIds
                for (int ii = 0; ii < numMTPModules; ii++)
                {
                    curReturnInputIdsPtr[ii] = curMTPPastTokensPtr[ii];
                }
            }

            // 2) For the new past hidden states
            copyChunkedHiddenStates(curMTPPastHiddenStatesPtr, curReturnHiddenStatesIdsPtr, numMTPModules * hiddenSize);
        }
    }
    else // For curMTPLayerIdx > 0
    {
        if (tid == 0)
        {
            // 1) For the new inputIds
            int numPastTokens = (bid < numContextRequest) ? curSeqLen : numMTPModules;
            for (int ii = 0; ii < numPastTokens; ii++)
            {
                curReturnInputIdsPtr[ii] = curInputIdsPtr[ii + 1];
            }
            curReturnInputIdsPtr[numPastTokens - 1] = previousLayerDraftTokens[bid];
        }

        // 2) For the new past hidden states
        // Directly use previous layer's output hidden states
    }
}

template <typename T>
void invokeMTPPrepareDrafterInputs(MTPPrepareDrafterInputsParam& params, cudaStream_t const stream)
{
    int constexpr BLOCK_SIZE = 512;
    TLLM_CHECK(
        params.hiddenSize * sizeof(T) % 16 == 0); // Which is because we will use float4 to copy the hidden states.

    mtpPrepareDrafterInputsKernel<T><<<params.batchSize, BLOCK_SIZE, 0, stream>>>(params.numMTPModules,
        params.curMTPLayerIdx, params.batchSize, params.numContextRequest, params.hiddenSize, params.inputIds,
        params.seqLens, reinterpret_cast<T**>(params.mtpPastHiddenStatesPtrs), params.mtpPastTokensPtrs,
        reinterpret_cast<T*>(params.previousLayerHiddenStates), params.previousLayerDraftTokens, params.returnInputIds,
        reinterpret_cast<T*>(params.returnHiddenStates));

    sync_check_cuda_error();
}

template void invokeMTPPrepareDrafterInputs<float>(MTPPrepareDrafterInputsParam& params, cudaStream_t stream);
template void invokeMTPPrepareDrafterInputs<half>(MTPPrepareDrafterInputsParam& params, cudaStream_t stream);
#ifdef ENABLE_BF16
template void invokeMTPPrepareDrafterInputs<__nv_bfloat16>(MTPPrepareDrafterInputsParam& params, cudaStream_t stream);
#endif

////////////////////////////////////////////////////////////////////////////////////////////////////////////

template <typename T, int BLOCK_SIZE>
__global__ void mtpGreedySampling(int const numMTPModules, int const batchSize, int const numContextRequest,
    int const vocabSize, T const* logits, int* targetTokens)
{
    /*
        In a batch of request: context request (at the beginning) + generation requests
        numGenerationRequest = batchSize - numContextRequest
        numLogits = numContextRequest + numGenerationRequest * (numMTPModules + 1)
        allDraftToken = numGenerationRequest * numMTPModules

        logits: [numLogits, vocabSize]
        targetTokens: [numLogits], temporary buffer
    */

    __shared__ T maxValueCache[BLOCK_SIZE];
    __shared__ int maxValueIndexCache[BLOCK_SIZE];

    int const bid = static_cast<int>(blockIdx.x);
    int const tid = static_cast<int>(threadIdx.x);

    // Do greedy sampliing for the input logits

    T const* curLogitsPtr = logits + bid * vocabSize;

    T tmpMaxValue = curLogitsPtr[0];
    int tmpMaxValueIndex = 0;
    int ii = tid;
    while (ii < vocabSize)
    {
        if (curLogitsPtr[ii] >= tmpMaxValue)
        {
            // Find the first top-1
            tmpMaxValueIndex = (curLogitsPtr[ii] == tmpMaxValue) ? min(tmpMaxValueIndex, ii) : ii;
            tmpMaxValue = curLogitsPtr[ii];
        }
        ii += blockDim.x;
    }
    maxValueCache[tid] = tmpMaxValue;
    maxValueIndexCache[tid] = tmpMaxValueIndex;

    __syncthreads();

    // reduction
    ii = min(blockDim.x, vocabSize) / 2;
    while (ii != 0)
    {
        if (tid < ii)
        {
            if (maxValueCache[tid] <= maxValueCache[tid + ii])
            {
                maxValueIndexCache[tid] = (maxValueCache[tid] == maxValueCache[tid + ii])
                    ? min(maxValueIndexCache[tid], maxValueIndexCache[tid + ii])
                    : maxValueIndexCache[tid + ii];
                maxValueCache[tid] = maxValueCache[tid + ii];
            }
        }
        __syncthreads();
        ii /= 2;
    }

    if (tid == 0)
    {
        targetTokens[bid] = maxValueIndexCache[tid];
    }
}

__global__ void mtpAcceptDraftToken(int const numMTPModules, int const batchSize, int const numContextRequest,
    int const* draftTokens, int* targetTokens, int* acceptedTokens, int* numAcceptedTokens)
{
    /*
        In a batch of request: context request (at the beginning) + generation requests
        numGenerationRequest = batchSize - numContextRequest
        numLogits = numContextRequest + numGenerationRequest * (numMTPModules + 1)
        allDraftToken = numGenerationRequest * numMTPModules

        draftTokens: [allDraftToken], flatten, remove padding
        targetTokens: [numLogits], temporary buffer
        acceptedTokens: [batchSize, numMTPModules + 1]
        numAcceptedTokens: [batchSize]
    */
    int const bid = static_cast<int>(blockIdx.x);
    int const tid = static_cast<int>(bid * blockDim.x + threadIdx.x);

    if (tid < batchSize)
    {
        // For the context requests, curDraftLen == 0
        // For the generation requests, curDraftLen == numMTPModules
        int curDraftLen = 0;
        if (tid >= numContextRequest)
        {
            // Generation request
            curDraftLen = numMTPModules;
        }

        int draftTokensStartOffset = -1;
        int targetTokensStartOffset = -1;

        if (tid < numContextRequest)
        {
            // Context requests
            draftTokensStartOffset = 0;    // context requests do not have draft tokens
            targetTokensStartOffset = tid; // the associated logits index
        }
        else
        {
            // Generation requests
            draftTokensStartOffset = (tid - numContextRequest) * numMTPModules;
            targetTokensStartOffset = numContextRequest + (tid - numContextRequest) * (numMTPModules + 1);
        }

        // Compare the draft tokens and target tokens
        int curAcceptedLen = 0;
        while ((curAcceptedLen < curDraftLen)
            && (draftTokens[draftTokensStartOffset + curAcceptedLen]
                == targetTokens[targetTokensStartOffset + curAcceptedLen]))
        {
            curAcceptedLen++;
        }
        curAcceptedLen++; // one more for the golden token
        numAcceptedTokens[tid] = curAcceptedLen;

        // Write back to acceptedTokens
        auto curAcceptedTokensPtr = acceptedTokens + tid * (numMTPModules + 1);
        for (int jj = 0; jj < curAcceptedLen; jj++)
        {
            curAcceptedTokensPtr[jj] = targetTokens[targetTokensStartOffset + jj];
        }
    }
}

template <typename T>
void invokeMTPSampleAndAcceptDraftTokens(MTPSampleAndAcceptDraftTokensParam& params, cudaStream_t const stream)
{
    int constexpr BLOCK_SIZE = 512;
    int numLogits
        = params.numContextRequest + (params.batchSize - params.numContextRequest) * (params.numMTPModules + 1);
    int greedyBlockSize = min(BLOCK_SIZE, params.vocabSize);

    mtpGreedySampling<T, BLOCK_SIZE><<<numLogits, greedyBlockSize, 0, stream>>>(params.numMTPModules, params.batchSize,
        params.numContextRequest, params.vocabSize, reinterpret_cast<T*>(params.logits), params.targetTokens);
    sync_check_cuda_error();

    mtpAcceptDraftToken<<<divUp(params.batchSize, BLOCK_SIZE), BLOCK_SIZE, 0, stream>>>(params.numMTPModules,
        params.batchSize, params.numContextRequest, params.draftTokens, reinterpret_cast<int*>(params.targetTokens),
        params.acceptedTokens, params.numAcceptedTokens);
    sync_check_cuda_error();
}

template void invokeMTPSampleAndAcceptDraftTokens<float>(
    MTPSampleAndAcceptDraftTokensParam& params, cudaStream_t stream);
template void invokeMTPSampleAndAcceptDraftTokens<half>(
    MTPSampleAndAcceptDraftTokensParam& params, cudaStream_t stream);
#ifdef ENABLE_BF16
template void invokeMTPSampleAndAcceptDraftTokens<__nv_bfloat16>(
    MTPSampleAndAcceptDraftTokensParam& params, cudaStream_t stream);
#endif

////////////////////////////////////////////////////////////////////////////////////////////////////////////
template <typename T>
__global__ void mtpUpdateHiddenStatesKernel(int const numMTPModules, int const batchSize, int const numContextRequest,
    int const hiddenSize, int const* inputIds, int const* seqLens, T* targetModelHiddenStates,
    T** mtpPastHiddenStatesPtrs, int** mtpPastTokensPtrs, int const* numAcceptedTokens, int const* acceptedTokens)
{
    /*
        In a batch of request: context request (at the beginning) + generation requests
        numGenerationRequest = batchSize - numContextRequest
        allTokens = sum(all prompts) + numGenerationRequest * (numMTPModules + 1)

        seqLens: [batchSize]
        targetModelHiddenStates: [allTokens, hiddenSize]
        mtpPastHiddenStatesPtrs: [maxNumRequests][numMTPModules, hiddenSize]
        mtpPastTokensPtrs: [maxNumRequests][numMTPModules]
        numAcceptedTokens: [batchSize]
        acceptedTokens: [batchSize][numMTPModules + 1], flatten
    */

    int const bid = static_cast<int>(blockIdx.x); // Each block is responsible for a request.
    int const tid = static_cast<int>(threadIdx.x);

    T* curMTPPastHiddenStatesPtr = mtpPastHiddenStatesPtrs[bid];
    int* curMTPPastTokensPtr = mtpPastTokensPtrs[bid];

    int curAcceptedLen = numAcceptedTokens[bid];
    int curSeqLen = seqLens[bid];

    int inputIdsStartOffset = 0;
    // TODO: better to optimize
    for (int i = 0; i < bid; i++)
    {
        inputIdsStartOffset += seqLens[i];
    }

    auto curInputIdsPtr = inputIds + inputIdsStartOffset;
    auto curTargetModelHiddenStatesPtr = targetModelHiddenStates + inputIdsStartOffset * hiddenSize;
    auto curAcceptedTokensPtr = acceptedTokens + bid * (numMTPModules + 1);

    // Update MTP tokens
    // Just use one thread to execute this copy
    if (tid == 0)
    {
        if (bid < numContextRequest)
        {
            // Context request
            // Copy the end of prompt tokens
            for (int ii = 0; ii < numMTPModules - 1; ii++)
            {
                curMTPPastTokensPtr[ii] = curInputIdsPtr[curSeqLen - numMTPModules + 1 + ii];
            }
            // Copy the new generated golden token
            curMTPPastTokensPtr[numMTPModules - 1] = curAcceptedTokensPtr[0];
        }
        else
        {
            // Copy the previous tokens
            int ii = 0;
            for (; ii < numMTPModules - curAcceptedLen; ii++)
            {
                curMTPPastTokensPtr[ii] = curMTPPastTokensPtr[curAcceptedLen + ii];
            }
            // Copy the accepted tokens
            int acceptedTokenStartIdx = max(0, curAcceptedLen - numMTPModules);
            for (; ii < numMTPModules; ii++, acceptedTokenStartIdx++)
            {
                curMTPPastTokensPtr[ii] = curAcceptedTokensPtr[acceptedTokenStartIdx];
            }
        }
    }

    // Update MTP hidden states
    // Use block to execute the copy of hidden states
    if (bid < numContextRequest)
    {
        // Context requests
        // Copy the end of prompt tokens [-numMTPModules:]
        auto srcPtr = curTargetModelHiddenStatesPtr + (curSeqLen - numMTPModules) * hiddenSize;
        copyChunkedHiddenStates<T>(srcPtr, curMTPPastHiddenStatesPtr, numMTPModules * hiddenSize);
    }
    else
    {
        // Generation requests
        // Copy previous hidden states
        auto srcPtr = curMTPPastHiddenStatesPtr + curAcceptedLen * hiddenSize;
        copyChunkedHiddenStates<T>(srcPtr, curMTPPastHiddenStatesPtr, (numMTPModules - curAcceptedLen) * hiddenSize);

        // Copy the accepted tokens' hidden states
        srcPtr = curTargetModelHiddenStatesPtr + max(0, curAcceptedLen - numMTPModules) * hiddenSize;
        auto dstPtr = curMTPPastHiddenStatesPtr + max(0, numMTPModules - curAcceptedLen) * hiddenSize;
        auto copyNum = numMTPModules - max(0, numMTPModules - curAcceptedLen);
        copyChunkedHiddenStates<T>(srcPtr, dstPtr, copyNum * hiddenSize);
    }
}

template <typename T>
void invokeMTPUpdateHiddenStates(MTPUpdateHiddenStatesParam& params, cudaStream_t const stream)
{
    int constexpr BLOCK_SIZE = 512;
    TLLM_CHECK(
        params.hiddenSize * sizeof(T) % 16 == 0); // Which is because we will use float4 to copy the hidden states.

    mtpUpdateHiddenStatesKernel<T><<<params.batchSize, BLOCK_SIZE, 0, stream>>>(params.numMTPModules, params.batchSize,
        params.numContextRequest, params.hiddenSize, params.inputIds, params.seqLens,
        reinterpret_cast<T*>(params.targetModelHiddenStates), reinterpret_cast<T**>(params.mtpPastHiddenStatesPtrs),
        params.mtpPastTokensPtrs, params.numAcceptedTokens, params.acceptedTokens);
    sync_check_cuda_error();
}

template void invokeMTPUpdateHiddenStates<float>(MTPUpdateHiddenStatesParam& params, cudaStream_t stream);
template void invokeMTPUpdateHiddenStates<half>(MTPUpdateHiddenStatesParam& params, cudaStream_t stream);
#ifdef ENABLE_BF16
template void invokeMTPUpdateHiddenStates<__nv_bfloat16>(MTPUpdateHiddenStatesParam& params, cudaStream_t stream);
#endif

} // namespace kernels
} // namespace tensorrt_llm
