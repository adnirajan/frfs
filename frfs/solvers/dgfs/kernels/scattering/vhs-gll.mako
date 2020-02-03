#include <cufft.h>

#define WM_DP

#if defined(WM_DP)
    #define Cplx cufftDoubleComplex
    #define scalar double
    #define Cos cos
    #define Sin sin

    static __device__ __host__ inline double sinc(const double s)
    {
        return sin(s+1e-15)/(s+1e-15);
    }

#elif defined(WM_SP)
    #define Cplx cufftFloatComplex
    #define scalar float
    #define Cos cosf
    #define Sin sinf

    static __device__ __host__ inline float sinc(const float s)
    {
        return sin(s+1e-6)/(s+1e-6);
    }

#else
    #error "undefined floating point data type"
#endif

<%!
import math 
%>

/*
static __device__ __host__ inline Cplx CplxMul(Cplx a, Cplx b) {
  Cplx c; c.x = a.x * b.x - a.y*b.y; c.y = a.x*b.y + a.y*b.x; return c;
}

static __device__ __host__ inline Cplx CplxAdd(Cplx a, Cplx b) {
  Cplx c; c.x = a.x + b.x; c.y = a.y + b.y; return c;
}
*/

__global__ void precompute_aa
(
    const scalar* d_lx,
    const scalar* d_ly,
    const scalar* d_lz,
    scalar* out
)
{
    int idx = blockIdx.x*blockDim.x + threadIdx.x;
    int id;

    if(idx<${vsize}) 
    {
        % for p in range(Nrho):
            <% fac =  math.pi/L*qz[p]/2. %>

            % for q in range(M):
                id = ${(p*M+q)*vsize}+idx;
                out[id] = ${fac}*((${sz[q,0]}*d_lx[idx]) 
                    + (${sz[q,1]}*d_ly[idx]) + (${sz[q,2]}*d_lz[idx])
                );
            % endfor
        % endfor
    }
}

__global__ void precompute_bb
(
    const scalar* d_lx,
    const scalar* d_ly,
    const scalar* d_lz,
    scalar* d_bb1,
    scalar* d_bb2
)
{
    int idx = blockIdx.x*blockDim.x + threadIdx.x;
    int id;
    scalar cSqr = 0., d_bb2_sum = 0.;

    if(idx<${vsize}) 
    {
        cSqr = sqrt(d_lx[idx]*d_lx[idx]
            + d_ly[idx]*d_ly[idx]
            + d_lz[idx]*d_lz[idx]);

        % for p in range(Nrho):
            id = ${p*vsize}+idx;
            d_bb1[id] = ${pow(qz[p],gamma+2.)*4*math.pi}
                        *sinc(${math.pi/L*qz[p]/2.}*cSqr);

            d_bb2_sum += ${qw[p]*pow(qz[p],gamma+2.)*16*math.pi*math.pi}
                        *sinc(${math.pi/L*qz[p]}*cSqr);
        % endfor

        d_bb2[idx] = d_bb2_sum;
    }
}

__global__ void cosSinMul
(
    const scalar* a,
    Cplx* FTf,
    Cplx* t1,
    Cplx* t2
)
{
    int idx = blockIdx.x*blockDim.x + threadIdx.x;
    //int idv = idx%${vsize};
    int id;
    scalar cosa, sina;

    //extern __shared__ Cplx sFTf[];
    if(idx<${vsize}) 
    {
        // scale
        FTf[idx].x /= ${vsize}; FTf[idx].y /= ${vsize};

        Cplx lFTf = FTf[idx];

        % for p in range(Nrho):
            % for q in range(M):

            id = ${(p*M+q)*vsize}+idx;
            cosa = cos(a[id]);
            sina = sin(a[id]);

            t1[id].x = cosa*lFTf.x;
            t1[id].y = cosa*lFTf.y;

            t2[id].x = sina*lFTf.x;
            t2[id].y = sina*lFTf.y;

            % endfor
        % endfor
    }
}

__global__ void magSqr
(
    const Cplx* in1,
    const Cplx* in2,
    Cplx* out
)
{
    int idx = blockIdx.x*blockDim.x + threadIdx.x;
    //int idv = idx%${vsize};
    int id;
    cufftDoubleComplex lin1, lin2;

    if(idx<${vsize}) 
    {
        % for p in range(Nrho):
            % for q in range(M):

                id = ${(p*M+q)*vsize}+idx;
                lin1 = in1[id];
                lin2 = in2[id];
                out[id].x = lin1.x*lin1.x - lin1.y*lin1.y
                            + lin2.x*lin2.x - lin2.y*lin2.y;
                out[id].y = 2*lin1.x*lin1.y + 2*lin2.x*lin2.y;

            % endfor
        % endfor
    }
}


__global__ void computeQG
(
    const scalar *d_bb1,
    const Cplx* d_t1,
    Cplx* d_QG
)
{
    int idx = blockIdx.x*blockDim.x + threadIdx.x;
    //int idv = idx%${vsize};
    scalar intw_p = 0;

    Cplx d_QG_sum;
    d_QG_sum.x = 0.; d_QG_sum.y = 0.; 

    //int id;
    if(idx<${vsize}) {
        
        //d_QG[idv].x = 0;
        //d_QG[idv].y = 0;
        
        % for p in range(Nrho):

            intw_p = ${2.*qw[p]*sw/vsize}*d_bb1[${p*vsize}+idx];

            % for q in range(M):

                //id = ${(p*M+q)*vsize}+idv;
                d_QG_sum.x += intw_p*d_t1[${(p*M+q)*vsize}+idx].x;
                d_QG_sum.y += intw_p*d_t1[${(p*M+q)*vsize}+idx].y;

            % endfor
        % endfor

        d_QG[idx] = d_QG_sum;
    }
}

__global__ void ax
(
    const double* d_bb2,
    Cplx* out
)
{
    int idx = blockIdx.x*blockDim.x + threadIdx.x;
    if(idx<${vsize}) {
        out[idx].x *= d_bb2[idx];
        out[idx].y *= d_bb2[idx];
    }
}

#define SOA_SZ ${soasz}
#define SOA_IX(a, v, nv) ((((a) / SOA_SZ)*(nv) + (v))*SOA_SZ + (a) % SOA_SZ)

__global__ void real
(
    const int nrow,
    const int ldim, 
    const int ncola, 
    const int ncolb,
    const int elem,
    const int upt,
    const Cplx* in_1,
    const Cplx* in_2,
    double* out
)
{
    int idx = blockIdx.x*blockDim.x + threadIdx.x;
    int idx_s = upt*ldim + SOA_IX(elem, idx, ncola);

    if(idx<${vsize}) {
        out[idx_s] = ${prefac}*(in_1[idx].x - in_2[idx].x);
    }
}

__global__ void output
(
    const int nrow,
    const int ldim, 
    const int ncola, 
    const int ncolb,
    const int elem,
    const int upt,
    const Cplx* in_1,
    const Cplx* in_2,
    double* in,
    double* out
)
{
    int idx = blockIdx.x*blockDim.x + threadIdx.x;
    int idx_s = upt*ldim + SOA_IX(elem, idx, ncola);

    if(idx<${vsize}) {
        out[idx_s] = ${prefac}*(in_1[idx].x - in[idx_s]*in_2[idx].x);
    }
}


/*
__global__ void r2z
(
    const double* in,
    Cplx* out
)
{
    int idx = blockIdx.x*blockDim.x + threadIdx.x;
    out[idx].x = in[idx];
    out[idx].y = 0.;
}
*/

__global__ void r2z
(
    const int nrow,
    const int ldim, 
    const int ncola, 
    const int ncolb,
    const int elem,
    const int upt,
    const double* in,
    Cplx* out
)
{
    int idx = blockIdx.x*blockDim.x + threadIdx.x;
    int idx_s = upt*ldim + SOA_IX(elem, idx, ncola);

    if(idx<${vsize}) {
        out[idx].x = in[idx_s];
        out[idx].y = 0.;
    }
}

__global__ void scale
(
    Cplx* out
)
{
    int idx = blockIdx.x*blockDim.x + threadIdx.x;

    if(idx<${vsize}) {
        out[idx].x /= ${vsize};
        out[idx].y /= ${vsize};
    }
}

__global__ void scale_MN
(
    Cplx* out
)
{
    int idx = blockIdx.x*blockDim.x + threadIdx.x;
    //int idv = idx%${vsize};
    int id;

    if(idx<${vsize}) 
    {
        % for p in range(Nrho):
            % for q in range(M):

                id = ${(p*M+q)*vsize}+idx;
                out[id].x /= ${vsize};
                out[id].y /= ${vsize};

            % endfor
        % endfor
    }
}



// Addition for the vhs-gll-nodal version

__global__ void cosMul
(
    const scalar* a,
    Cplx* FTf,
    Cplx* FTg,
    Cplx* t1,
    Cplx* t2
)
{
    int idx = blockIdx.x*blockDim.x + threadIdx.x;
    //int idv = idx%${vsize};
    int id;
    scalar cosa;

    //extern __shared__ Cplx sFTf[];
    if(idx<${vsize}) 
    {
        // scale
        FTf[idx].x /= ${vsize}; FTf[idx].y /= ${vsize};
        FTg[idx].x /= ${vsize}; FTg[idx].y /= ${vsize};

        Cplx lFTf = FTf[idx];
        Cplx lFTg = FTg[idx];

        % for p in range(Nrho):
            % for q in range(M):

            id = ${(p*M+q)*vsize}+idx;
            cosa = cos(a[id]);

            t1[id].x = cosa*lFTf.x;
            t1[id].y = cosa*lFTf.y;

            t2[id].x = cosa*lFTg.x;
            t2[id].y = cosa*lFTg.y;

            % endfor
        % endfor
    }
}

// Note the scaling is performed in the cosMul
__global__ void sinMul
(
    const scalar* a,
    Cplx* FTf,
    Cplx* FTg,
    Cplx* t1,
    Cplx* t2
)
{
    int idx = blockIdx.x*blockDim.x + threadIdx.x;
    //int idv = idx%${vsize};
    int id;
    scalar sina;

    //extern __shared__ Cplx sFTf[];
    if(idx<${vsize}) 
    {
        // scale
        //FTf[idx].x /= ${vsize}; FTf[idx].y /= ${vsize};
        //FTg[idx].x /= ${vsize}; FTg[idx].y /= ${vsize};

        Cplx lFTf = FTf[idx];
        Cplx lFTg = FTg[idx];

        % for p in range(Nrho):
            % for q in range(M):

            id = ${(p*M+q)*vsize}+idx;
            sina = sin(a[id]);

            t1[id].x = sina*lFTf.x;
            t1[id].y = sina*lFTf.y;

            t2[id].x = sina*lFTg.x;
            t2[id].y = sina*lFTg.y;

            % endfor
        % endfor
    }
}


__global__ void cplxMul
(
    const Cplx* in1,
    const Cplx* in2,
    Cplx* out
)
{
    int idx = blockIdx.x*blockDim.x + threadIdx.x;
    //int idv = idx%${vsize};
    int id;
    cufftDoubleComplex lin1, lin2;

    if(idx<${vsize}) 
    {
        % for p in range(Nrho):
            % for q in range(M):

                id = ${(p*M+q)*vsize}+idx;
                lin1 = in1[id];
                lin2 = in2[id];
                out[id].x = lin1.x*lin2.x - lin1.y*lin2.y;
                out[id].y = lin1.x*lin2.y + lin1.y*lin2.x;

            % endfor
        % endfor
    }
}

__global__ void cplxMulAdd
(
    const Cplx* in1,
    const Cplx* in2,
    Cplx* out
)
{
    int idx = blockIdx.x*blockDim.x + threadIdx.x;
    //int idv = idx%${vsize};
    int id;
    cufftDoubleComplex lin1, lin2;

    if(idx<${vsize}) 
    {
        % for p in range(Nrho):
            % for q in range(M):

                id = ${(p*M+q)*vsize}+idx;
                lin1 = in1[id];
                lin2 = in2[id];
                out[id].x += lin1.x*lin2.x - lin1.y*lin2.y;
                out[id].y += lin1.x*lin2.y + lin1.y*lin2.x;

            % endfor
        % endfor
    }
}