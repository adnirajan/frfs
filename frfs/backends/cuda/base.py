# -*- coding: utf-8 -*-

import os
import re

from frfs.backends.base import BaseBackend
from frfs.mpiutil import get_local_rank


class CUDABackend(BaseBackend):
    name = 'cuda'

    def __init__(self, cfg):
        super().__init__(cfg)

        # Get the desired CUDA device
        devid = cfg.get('backend-cuda', 'device-id', 'local-rank')
        if not re.match(r'(round-robin|local-rank|\d+)$', devid):
            raise ValueError('Invalid device-id')

        # In the non round-robin case set CUDA_DEVICE to be the desired
        # CUDA device number (used by pycuda.autoinit)
        os.environ.pop('CUDA_DEVICE', None)

        # Handle the local-rank case
        if devid == 'local-rank':
            devord = str(get_local_rank())
            os.environ['CUDA_DEVICE'] = devord

        # Create a CUDA context
        from pycuda.autoinit import context
        import pycuda.driver as cuda

        # Aforementioned commented lines do not work for multiple gpus/node
        """
        if devid == 'local-rank':
            import pycuda.driver as cuda            
            cuda.init()
            cudadevice = cuda.Device(int(devord))
            context = cudadevice.make_context()
            #import atexit
            #atexit.register(context.pop)
        elif devid == 'round-robin':
            from pycuda.autoinit import context
            import pycuda.driver as cuda
        """

        # Take the required alignment to be 128 bytes
        self.alignb = 128

        # Take the SoA size to be 32 elements
        self.soasz = 32

        # Get the MPI runtime type
        self.mpitype = cfg.get('backend-cuda', 'mpi-type', 'standard')
        if self.mpitype not in {'standard', 'cuda-aware'}:
            raise ValueError('Invalid CUDA backend MPI type')

        # Some CUDA devices share L1 cache and shared memory; on these
        # devices CUDA allows us to specify a preference between L1
        # cache and shared memory.  For the sake of CUBLAS (which
        # benefits greatly from more shared memory but fails to
        # declare its preference) we set the global default to
        # PREFER_SHARED.
        context.set_cache_config(cuda.func_cache.PREFER_SHARED)
        #self.context = context

        from frfs.backends.cuda import (blasext, cublas, gimmik, packing,
                                        provider, types)

        # Register our data types
        self.base_matrix_cls = types.CUDAMatrixBase
        self.const_matrix_cls = types.CUDAConstMatrix
        self.matrix_cls = types.CUDAMatrix
        self.matrix_bank_cls = types.CUDAMatrixBank
        self.matrix_rslice_cls = types.CUDAMatrixRSlice
        self.queue_cls = types.CUDAQueue
        self.view_cls = types.CUDAView
        self.xchg_matrix_cls = types.CUDAXchgMatrix
        self.xchg_view_cls = types.CUDAXchgView

        # Instantiate the base kernel providers
        kprovs = [provider.CUDAPointwiseKernelProvider,
                  blasext.CUDABlasExtKernels,
                  packing.CUDAPackingKernels,
                  gimmik.CUDAGiMMiKKernels,
                  cublas.CUDACUBLASKernels]
        self._providers = [k(self) for k in kprovs]

        # Pointwise kernels
        self.pointwise = self._providers[0]

    def _malloc_impl(self, nbytes):
        import pycuda.driver as cuda

        # Allocate
        data = cuda.mem_alloc(nbytes)

        # Zero
        cuda.memset_d32(data, 0, nbytes // 4)

        return data
