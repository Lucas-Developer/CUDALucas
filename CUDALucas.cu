static const char RCSMacLucasFFTW_c[] = "$Id: MacLucasFFTW.c,v 8.1 2007/06/23 22:33:35 wedgingt Exp $ wedgingt@acm.org";
const char *RCSprogram_id = RCSMacLucasFFTW_c;
const char *program_name = "CUDALucas"; /* for perror() and similar */
const char program_revision[] = "$Revision: 1.3alpha_ah42$";
char version[sizeof(RCSMacLucasFFTW_c) + sizeof(program_revision)]; /* overly long, but certain */

/* CUDALucas.c
Shoichiro Yamada Oct. 2010 */

/* The following comment is by Guillermo Ballester Valor.  Feel free to send me email
about problems as well.  --Will Edgington, wedgingt@acm.org */

/* MacLucasFFTW.c

lucaslfftw v.1.0.0
Guillermo Ballester Valor, Oct. 1999
gbv@ctv.es

This is an adaptation of Richard Crandall lucdwt.c and Sweeney 
MacLucasUNIX.c code.  There are few things mine own.

The memory requirements is about q bytes, where q is the exponent of
mersenne number being tested. (m(q))

This modification is designed to use the GNU package FFTW (the Fastest 
Fourier Transform in the West). http://www.fftw.org

I would like to know if this is true. I've already made some adaptation
of GNU-GMP pakage and really is the fastest of the general C-written FFT 
packages I tried (in a Pentium 166-mmx). This has some important 
advantages:

1) It can use other than power of two FFT's lenghts.

2) For a given FFT length, It can search the best FFT scheme in a system.
When it had found is 'optimal' solution, it can store it in a file or
string and use it whenever it needed.

3) It can be called with MULTITREADS flags to be used in system with more
than one processor.


At the monment, what I made is :
a) Remove all FFT code from lucdwt and the awful add_signal and 
patch routines. It has been replaced by an adaptation of MacLucasUNIX
normalize, normalize_last and the main routines.

b) Change the code lines needed to support other lengths than power of two.

c) Introduce some small routines to select the FFT lengths.

d) Use the 'fftw.pln' file generated by my own tunefftw program
for maximum performance with FFTW package.

e) and some other minor changes I don't remember.. :-)

WHAT YOU NEED TO RUN THIS?

i) Obviously to install FFTW package.
See http://www.fftw.org
Its a very vell documented package. I've installed from source files
with:
./configure
make
make install
ii) Make the tune_fftw program. It's very simple to make. The source code
is joined with this one. The link option must include -lrfftw -lfftw -lm

iii) Make this simple program. Again the linker option must have -lm -lrfftw -lfftw

iv) And try it like original MacLucasUNIX.

Please, let me know any problem.

*/

/* Include Files */

#include <stdlib.h>
#include <stdio.h>
#include <math.h>
#include <assert.h>

#include <cuda.h>
#include <cuda_runtime.h>
#include <cufft.h>
#include "cuda_safecalls.h"

/* some include needed for mers package */
#include "setup.h"
#include "balance.h"
#include "rw.h"

/* some definitions needed by mers package */
#define kErrLimit (0.35)
#define kErrChkFreq (100)
#define kErrChk (1)
#define kLast (2)

/************************ definitions ************************************/


/* This used to try to align to an even multiple of 16 BIG_DOUBLEs in */
/*  Guillermo's original version, but adjusting pointers from malloc() */
/*  causes core dumps when they're later passed to free().  Is there */
/*  another way to do the same thing?  --wedgingt@acm.org */
#ifdef linux
#define ALLOC_DOUBLES(n) ((double *)memalign(128,(n)*sizeof(double)))
#else
#define ALLOC_DOUBLES(n) ((double *)malloc((n)*sizeof(double)))
#endif
/* global variables needed */
double     *two_to_phi, *two_to_minusphi;
double     *g_ttp,*g_ttmp;
float          *g_inv;
double     high,low,highinv,lowinv;
double     Gsmall,Gbig,Hsmall,Hbig;
UL             b, c;
cufftHandle    plan;
FILE           *wisdom_file;
double *g_x;
double *g_maxerr;
double *g_carry;

/********  The TRICK to round to nearest *******************************/
/* This plays with the internal hardward round to nearest when we add a
small number to a very big number, called bigA number. For intel fpu
this is 3*2^62. Then you have to sustract the same number (named different 
to confuse the clever compilers). This makes rint() very fast.

*/

double     bigA,bigB;

/* rint is not ANSI compatible, so we need a definition for 
* WIN32 and other platforms with rint.
* Also we use that to write the trick to rint()
*/

#if defined(__x86_32__)
#define RINT(x) (floor(x+0.5))	
#else
#define RINT(x) (((x) + A ) - B)
#endif

/*
http://www.kurims.kyoto-u.ac.jp/~ooura/fft.html

base code is Mr. ooura's FFT.

Fast Fourier/Cosine/Sine Transform
dimension   :one
data length :power of 2
decimation  :frequency
radix       :4, 2
data        :inplace
table       :use
functions
rdft: Real Discrete Fourier Transform
Appendix :
The cos/sin table is recalculated when the larger table required.
w[] and ip[] are compatible with all routines.
*/

__global__ void rftfsub_kernel(int n, double *a)
{
    const int threadID = blockIdx.x * blockDim.x + threadIdx.x;
    int j,m,nc;
    double wkr, wki, xr, xi, yr, yi,cc,d,aj,aj1,ak,ak1, *c ;

    c = &a[n+n/4+512*512];
    nc = n >> 2 ;
    m = n >> 1;

    j = threadID * 2 ;
    if(threadID != 0)
    {
        wkr = 0.5 - c[nc-j/2];
        wki = c[j/2];
        aj = a[j];
        aj1 = a[1+j];
        ak = a[n-j];
        ak1 = a[1+n-j];
        xr = aj - ak;
        xi = aj1 + ak1;
        yr = wkr * xr - wki * xi;
        yi = wkr * xi + wki * xr;
        aj -= yr;
        aj1 -= yi;
        ak += yr;
        ak1 -= yi;
        cc = aj;
        d = -aj1;
        aj1 = -2.0*cc*d;
        aj = (cc+d)*(cc-d);
        cc = ak;
        d = -ak1;
        ak1 = -2.0*cc*d;
        ak = (cc+d)*(cc-d);
        xr = aj - ak;
        xi = aj1 + ak1;
        yr = wkr * xr + wki * xi;
        yi = wkr * xi - wki * xr;
        aj -= yr;
        aj1 = yi - aj1;
        ak += yr;
        ak1 = yi - ak1;
        a[j]=aj;
        a[1+j]=aj1;
        a[n-j]=ak;
        a[1+n-j]=ak1;
    } 
    else 	
    {
        xi = a[0] - a[1];
        a[0] += a[1];
        a[1] = xi;
        a[0] *= a[0];
        if ((n & 1) == 0) a[1] *= a[1];
        a[1] = 0.5 * (a[0] - a[1]);
        a[0] -= a[1];
        a[1] = -a[1];
        cc = a[0+m];
        d = -a[1+m];
        a[1+m] = -2.0*cc*d;
        a[0+m] = (cc+d)*(cc-d);
        a[1+m] = -a[1+m];
    }
}

void rdft(int n, double *a, int *ip)
{
    void makewt(int nw, int *ip, double *w);
    void makect(int nc, int *ip, double *c);
    int nw, nc;

    nw = ip[0];
    if(nw == 0){
        nw = n >> 2;
        makewt(nw, ip, &a[n+512*512]);
        nc = ip[1];
        nc = n >> 2;
        makect(nc, ip, &a[n+512*512] + nw);
        cutilSafeCall(cudaMemcpy(g_x, a, sizeof(double)*(n/2*3+512*512), cudaMemcpyHostToDevice));
    }
    cufftSafeCall(cufftExecZ2Z(plan,(cufftDoubleComplex *)g_x,(cufftDoubleComplex *)g_x, CUFFT_INVERSE));
    rftfsub_kernel <<< n/512,128 >>> (n,g_x);
    cufftSafeCall(cufftExecZ2Z(plan,(cufftDoubleComplex *)g_x,(cufftDoubleComplex *)g_x, CUFFT_INVERSE));
    return;
}

/* -------- initializing routines -------- */
void makewt(int nw, int *ip, double *w)
{
    void bitrv2(int n, int *ip, double *a);
    int j, nwh;
    double delta, x, y;

    ip[0] = nw;
    ip[1] = 1;
    if (nw > 2) {
        nwh = nw >> 1;
        delta = atan(1.0) / nwh;
        w[0] = 1;
        w[1] = 0;
        w[nwh] = cos(delta * nwh);
        w[nwh + 1] = w[nwh];
        if (nwh > 2) {
            for (j = 2; j < nwh; j += 2) {
                x = cos(delta * j);
                y = sin(delta * j);
                w[j] = x;
                w[j + 1] = y;
                w[nw - j] = y;
                w[nw - j + 1] = x;
            }
            bitrv2(nw, ip + 2, w);
        }
    }
}

void makect(int nc, int *ip, double *c)
{
    int j,nch;
    double delta;

    ip[1] = nc;
    if (nc > 1) {
        nch = nc >> 1;
        delta = atan(1.0) / nch;
        c[0] = cos(delta * nch);
        c[nch] = 0.5 * c[0];
        for (j = 1; j < nch; j++) {
            c[j] = 0.5 * cos(delta * j);
            c[nc - j] = 0.5 * sin(delta * j);
        }
    }
}

/* -------- child routines -------- */
void bitrv2(int n, int *ip, double *a)
{
    int j,j1,k,k1,l,m,m2;
    double xr,xi,yr,yi;

    ip[0] = 0;
    l = n;
    m = 1;
    while ((m << 3) < l) {
        l >>= 1;
        for (j = 0; j < m; j++) {
            ip[m + j] = ip[j] + l;
        }
        m <<= 1;
    }
    m2 = 2 * m;
    if ((m << 3) == l) {
        for (k = 0; k < m; k++) {
            for (j = 0; j < k; j++) {
                j1 = 2 * j + ip[k];
                k1 = 2 * k + ip[j];
                xr = a[j1];
                xi = a[j1 + 1];
                yr = a[k1];
                yi = a[k1 + 1];
                a[j1] = yr;
                a[j1 + 1] = yi;
                a[k1] = xr;
                a[k1 + 1] = xi;
                j1 += m2;
                k1 += 2 * m2;
                xr = a[j1];
                xi = a[j1 + 1];
                yr = a[k1];
                yi = a[k1 + 1];
                a[j1] = yr;
                a[j1 + 1] = yi;
                a[k1] = xr;
                a[k1 + 1] = xi;
                j1 += m2;
                k1 -= m2;
                xr = a[j1];
                xi = a[j1 + 1];
                yr = a[k1];
                yi = a[k1 + 1];
                a[j1] = yr;
                a[j1 + 1] = yi;
                a[k1] = xr;
                a[k1 + 1] = xi;
                j1 += m2;
                k1 += 2 * m2;
                xr = a[j1];
                xi = a[j1 + 1];
                yr = a[k1];
                yi = a[k1 + 1];
                a[j1] = yr;
                a[j1 + 1] = yi;
                a[k1] = xr;
                a[k1 + 1] = xi;
            }
            j1 = 2 * k + m2 + ip[k];
            k1 = j1 + m2;
            xr = a[j1];
            xi = a[j1 + 1];
            yr = a[k1];
            yi = a[k1 + 1];
            a[j1] = yr;
            a[j1 + 1] = yi;
            a[k1] = xr;
            a[k1 + 1] = xi;
        }
    } else {
        for (k = 1; k < m; k++) {
            for (j = 0; j < k; j++) {
                j1 = 2 * j + ip[k];
                k1 = 2 * k + ip[j];
                xr = a[j1];
                xi = a[j1 + 1];
                yr = a[k1];
                yi = a[k1 + 1];
                a[j1] = yr;
                a[j1 + 1] = yi;
                a[k1] = xr;
                a[k1 + 1] = xi;
                j1 += m2;
                k1 += m2;
                xr = a[j1];
                xi = a[j1 + 1];
                yr = a[k1];
                yi = a[k1 + 1];
                a[j1] = yr;
                a[j1 + 1] = yi;
                a[k1] = xr;
                a[k1 + 1] = xi;
            }
        }
    }
}

#define BLOCK_DIM 16

// This kernel is optimized to ensure all global reads and writes are coalesced,
// and to avoid bank conflicts in shared memory.  This kernel is up to 11x faster
// than the naive kernel below.  Note that the shared memory array is sized to 
// (BLOCK_DIM+1)*BLOCK_DIM.  This pads each row of the 2D block in shared memory 
// so that bank conflicts do not occur when threads address the array column-wise.

// This is templated because the transpose is square. We can eliminate the branching
// from the if statements because we know height and width are identical
template <int width>
__global__ void square_transpose(double *odata, double *idata)
{
    __shared__ double block[BLOCK_DIM][BLOCK_DIM+1];

    // read the matrix tile into shared memory
    unsigned int xIndex = blockIdx.x * BLOCK_DIM + threadIdx.x;
    unsigned int yIndex = blockIdx.y * BLOCK_DIM + threadIdx.y;
    
    unsigned int index_in = yIndex * width + xIndex;
    block[threadIdx.y][threadIdx.x] = idata[index_in];

    __syncthreads();

    // write the transposed matrix tile to global memory
    xIndex = blockIdx.y * BLOCK_DIM + threadIdx.x;
    yIndex = blockIdx.x * BLOCK_DIM + threadIdx.y;
    
    unsigned int index_out = yIndex * width + xIndex;
    odata[index_out] = block[threadIdx.x][threadIdx.y];
}

template <int width>
__global__ void square_transposef(float *odata, double *idata)
{
    __shared__ double block[BLOCK_DIM][BLOCK_DIM+1];

    // read the matrix tile into shared memory
    unsigned int xIndex = blockIdx.x * BLOCK_DIM + threadIdx.x;
    unsigned int yIndex = blockIdx.y * BLOCK_DIM + threadIdx.y;
    
    unsigned int index_in = yIndex * width + xIndex;
    block[threadIdx.y][threadIdx.x] = idata[index_in];

    __syncthreads();

    // write the transposed matrix tile to global memory
    xIndex = blockIdx.y * BLOCK_DIM + threadIdx.x;
    yIndex = blockIdx.x * BLOCK_DIM + threadIdx.y;
    unsigned int index_out = yIndex * width + xIndex;
    odata[index_out] = block[threadIdx.x][threadIdx.y];
}

/****************************************************************************
*           Lucas Test - specific routines                                 *
***************************************************************************/

void init_lucas(UL q, UL n)
{
    UL j,qn,a,i,done;
    UL size0,bj;
    double log2 = log(2.0);
    double ttp,ttmp;
    double *s_inv,*s_ttp,*s_ttmp;

    two_to_phi = ALLOC_DOUBLES(n/2);
    two_to_minusphi = ALLOC_DOUBLES(n/2);
    s_inv = ALLOC_DOUBLES(n);
    s_ttp = ALLOC_DOUBLES(n);
    s_ttmp = ALLOC_DOUBLES(n);

    if (g_x != NULL)
    {
        cutilSafeCall(cudaFree((char *)g_x));
        cutilSafeCall(cudaFree((char *)g_maxerr));
        cutilSafeCall(cudaFree((char *)g_carry));
        cutilSafeCall(cudaFree((char *)g_inv));
        cutilSafeCall(cudaFree((char *)g_ttp));
        cutilSafeCall(cudaFree((char *)g_ttmp));
    }

    cutilSafeCall(cudaMalloc((void**)&g_x, sizeof(double)*(n/2*3+512*512)));
    cutilSafeCall(cudaMalloc((void**)&g_maxerr, sizeof(double)*n/512));
    cutilSafeCall(cudaMalloc((void**)&g_carry, sizeof(double)*n/512));
    cutilSafeCall(cudaMalloc((void**)&g_inv,sizeof(double)*n/2));
    cutilSafeCall(cudaMalloc((void**)&g_ttp,sizeof(double)*n));
    cutilSafeCall(cudaMalloc((void**)&g_ttmp,sizeof(double)*n));

    cufftSafeCall(cufftPlan1d(&plan, n/2, CUFFT_Z2Z, 1));

    low = floor((exp(floor((double)q/n)*log2))+0.5);
    high = low+low;
    lowinv = 1.0/low;
    highinv = 1.0/high;
    b = q % n;
    c = n-b;

    two_to_phi[0] = 1.0;
    two_to_minusphi[0] = 1.0/(double)(n);
    qn = (b*2)%n;

    for(i=1,j=2; j<n; j+=2,i++)
    {
        a = n - qn;
        two_to_phi[i] = exp(a*log2/n);
        two_to_minusphi[i] = 1.0/(two_to_phi[i]*n);
        qn+=b*2;
        qn%=n;
    }

    Hbig = exp(c*log2/n);
    Gbig = 1/Hbig;
    done = 0;
    j = 0;
    while (!done)
    {
        if (!((j*b) % n >=c || j==0))
        {
            a = n -((j+1)*b)%n;
            i = n -(j*b)%n;
            Hsmall = exp(a*log2/n)/exp(i*log2/n);
            Gsmall = 1/Hsmall;
            done = 1;
        }
        j++;
    }
    bj = n;
    size0 = 1;
    bj = n - 1 * b;

    for (j=0,i=0; j<n; j=j+2,i++)
    {
        ttmp = two_to_minusphi[i];
        ttp = two_to_phi[i];

        bj += b;
        bj = bj & (n-1);
        size0 = (bj>=c);
        if(j == 0) size0 = 1;
        s_ttmp[j]=ttmp*2.0;
        if (size0)
        {
            s_inv[j]=highinv;
            ttmp *=Gbig;
            s_ttp[j]=ttp * high;
            ttp *= Hbig;
        }
        else
        {
            s_inv[j]=lowinv;
            ttmp *=Gsmall;
            s_ttp[j]=ttp * low;
            ttp *= Hsmall;
        }
        bj += b;
        bj = bj & (n-1);
        size0 = (bj>=c);

        if (j==(n-2)) size0 = 0;
        s_ttmp[j+1]=ttmp*-2.0;
        if (size0)
        {
            s_inv[j+1]=highinv;
            s_ttp[j+1]=ttp * high;
        }
        else
        {
            s_inv[j+1]=lowinv;
            s_ttp[j+1]=ttp * low;
        }
    }
    dim3 grid(512 / BLOCK_DIM, 512 / BLOCK_DIM, 1);
    dim3 threads(BLOCK_DIM, BLOCK_DIM, 1);

    cudaMemcpy(g_x,s_inv,sizeof(double)*n,cudaMemcpyHostToDevice);
    for(i=0;i<n;i+=(512*512))
        square_transposef<512><<< grid, threads >>>((float *)&g_inv[i],(double *)&g_x[i]);
    cudaMemcpy(g_x,s_ttp,sizeof(double)*n,cudaMemcpyHostToDevice);
    for(i=0;i<n;i+=(512*512))
        square_transpose<512><<< grid, threads >>>((double *)&g_ttp[i],(double *)&g_x[i]);
    cudaMemcpy(g_x,s_ttmp,sizeof(double)*n,cudaMemcpyHostToDevice);
    for(i=0;i<n;i+=(512*512))
        square_transpose<512><<< grid, threads >>>((double *)&g_ttmp[i],(double *)&g_x[i]);
    if (s_inv != NULL) free((char *)s_inv);
    if (s_ttp != NULL) free((char *)s_ttp);
    if (s_ttmp != NULL) free((char *)s_ttmp);
}

#define IDX(i) ((((i) >> 18) << 18) + (((i) & (512*512-1)) >> 9)  + ((i & 511) << 9))
template <bool g_err_flag, int stride>
__global__ void normalize_kernel(double *g_xx, double A, double B, double *g_maxerr, double *g_carry,
		float *g_inv, double *g_ttp, double *g_ttmp)
{
    const int threadID = blockIdx.x * blockDim.x + threadIdx.x;
    const int js= stride * threadID;

    double carry = (threadID==0) ? -2.0 : 0.0; /* this is the -2 of the LL x*x - 2 */

    if (g_err_flag) {
	    double maxerr=0.0, err=0.0, tempErr, temp0;
#pragma unroll 4
	    for (int j=0; j < stride; j++) {
		    temp0 = g_xx[IDX(j + js)];
		    tempErr = RINT( temp0 * g_ttmp[IDX(j + js)] );
		    err = fabs( (temp0 * g_ttmp[IDX(j + js)]) - tempErr);
		    temp0 = tempErr + carry;
		    temp0 *= g_inv[IDX(j + js)];
		    carry = RINT(temp0);
		    g_xx[IDX(j + js)] = (temp0-carry) * g_ttp[IDX(j + js)];
		    if (err > maxerr) {
			    maxerr = err;
		    }
	    }
	    g_maxerr[threadID]=maxerr;

    } else {
	    double4 buf[4];
	    int4 idx;
	    double2 temp0;
#pragma unroll 1
	    for (int j=0; j < stride; j+=4) {
		    idx.x = IDX((j + js));
		    idx.y = IDX((j + js) + 1);
		    idx.z = IDX((j + js) + 2);
		    idx.w = IDX((j + js) + 3);
		    buf[0].x = g_xx[idx.x];
		    buf[0].y = g_xx[idx.y];
		    buf[0].z = g_xx[idx.z];
		    buf[0].w = g_xx[idx.w];
		    buf[1].x = g_ttmp[idx.x];
		    buf[1].y = g_ttmp[idx.y];
		    buf[1].z = g_ttmp[idx.z];
		    buf[1].w = g_ttmp[idx.w];
		    buf[2].x = g_inv[idx.x];
		    buf[2].y = g_inv[idx.y];
		    buf[2].z = g_inv[idx.z];
		    buf[2].w = g_inv[idx.w];
		    buf[3].x = g_ttp[idx.x];
		    buf[3].y = g_ttp[idx.y];
		    buf[3].z = g_ttp[idx.z];
		    buf[3].w = g_ttp[idx.w];
		    
		    temp0.x  = RINT(buf[0].x*buf[1].x);
		    temp0.y  = RINT(buf[0].y*buf[1].y);
		    temp0.x += carry;
		    temp0.x *= buf[2].x;
		    carry    = RINT(temp0.x);
		    temp0.x  = (temp0.x-carry) * buf[3].x;
		    
		    temp0.y += carry;
		    temp0.y *= buf[2].y;
		    carry    = RINT(temp0.y);
		    temp0.y  = (temp0.y-carry) * buf[3].y;
		    
		    g_xx[idx.x] = temp0.x;
		    g_xx[idx.y] = temp0.y;
		    
		    temp0.x  = RINT(buf[0].z*buf[1].z);
		    temp0.y  = RINT(buf[0].w*buf[1].w);
		    temp0.x += carry;
		    temp0.x *= buf[2].z;
		    carry    = RINT(temp0.x);
		    temp0.x  = (temp0.x-carry) * buf[3].z;
		    
		    temp0.y += carry;
		    temp0.y *= buf[2].w;
		    carry    = RINT(temp0.y);
		    temp0.y  = (temp0.y-carry) * buf[3].w;
		    
		    g_xx[idx.z] = temp0.x;
		    g_xx[idx.w] = temp0.y;
		    
	    }
    }
    
    g_carry[threadID]=carry;
}

__global__ void normalize2_kernel(double *g_xx,double A,double B,
    double *g_maxerr,double *g_carry,UL g_N,
    float *g_inv,double *g_ttp,double *g_ttmp)
{
    const int threadID = blockIdx.x * blockDim.x + threadIdx.x;
    const int stride = 512;
    const int js= stride * threadID;
    const int je= js + stride;
    UL j;
    double temp0,tempErr;
    double carry;
    int k,ke;

    k=je;
    ke = k + stride;
    if(je == g_N)
    {
        k=0;
        ke = k + stride;
    }
    carry = g_carry[threadID];

    for (j=k; carry != 0.0 && j<ke; j+=2)
    {
        temp0 = g_xx[IDX(j)];
        tempErr = RINT( temp0*g_ttmp[IDX(j)]*0.5*g_N );
        temp0 = tempErr + carry;
        temp0 *= g_inv[IDX(j)];
        carry = RINT(temp0);
        g_xx[IDX(j)] = (temp0-carry) * g_ttp[IDX(j)];

        temp0 = g_xx[IDX(j+1)];
        tempErr = RINT( temp0*g_ttmp[IDX(j+1)]*(-0.5)*g_N );
        temp0 = tempErr + carry;
        temp0 *= g_inv[IDX(j+1)];
        carry = RINT(temp0);
        g_xx[IDX(j+1)] = (temp0-carry) * g_ttp[IDX(j+1)];
    }
}

double last_normalize(double *x,UL N,UL err_flag )
{
    UL i,j,k,bj;
    UL size0;
    double hi=high, hiinv=highinv, lo=low, loinv=lowinv;
    double temp0,tempErr;
    double maxerr=0.0,err=0.0,ttmpSmall=Gsmall,ttmpBig=Gbig,ttmp;
	double carry;
	double A=bigA,B=bigB;

    carry = - 2.0; /* this is the -2 of the LL x*x - 2 */
    bj=N;
    size0 = 1;

    for (j=0,i=0;j<N;j+=2,i++) 
    {
        ttmp = two_to_minusphi[i];
        temp0 = x[j];
        temp0 *=2.0;
        tempErr = RINT(temp0*ttmp);
        if (err_flag) 
        {
            err = fabs(temp0*ttmp-tempErr);
            if (err>maxerr) maxerr=err;
        }
        temp0 = tempErr + carry;
        if (size0) 
        {
            temp0 *= hiinv;
            carry = RINT(temp0);
            bj+=b;
            ttmp *=ttmpBig;
            if(bj>=N) bj -= N; 
            x[j] = (temp0-carry) * hi;
            size0 = (bj>=c);
        }
        else 
        {
            temp0 *= loinv;
            carry = RINT(temp0);
            bj+=b;
            ttmp *=ttmpSmall;
            if(bj>=N) bj -= N; 
            x[j] = (temp0-carry) * lo;
            size0 = (bj>=c);
        }
        temp0 = x[j+1];
        temp0 *=-2.0;

        if (j==N-2) size0 = 0;
        tempErr = RINT(temp0*ttmp);
        if (err_flag) 
        {
            err = fabs(temp0*ttmp-tempErr);
            if (err>maxerr) maxerr=err;
        }
        temp0 = tempErr + carry;
        if (size0) 
        {
            temp0 *= hiinv;
            carry = RINT(temp0);
            bj+=b;
            ttmp *=ttmpBig;
            if(bj>=N) bj -= N; 
            x[j+1] = (temp0-carry) * hi;
            size0 = (bj>=c);
        }
        else 
        {
            temp0 *= loinv;
            carry = RINT(temp0);
            bj+=b;
            ttmp *=ttmpSmall;
            if(bj>=N) bj -= N; 
            x[j+1] = (temp0-carry) * lo;
            size0 = (bj>=c);
        }
    }
    bj = N;
    k=0;
    while(carry != 0)
    {
        size0 = (bj>=c);
        bj += b;
        temp0 = (x[k] + carry);
        if(bj >= N) bj-=N;  
        if (size0)
        {
            temp0 *= hiinv;
            carry = RINT(temp0);
            x[k] = (temp0 -carry) * hi;
        }
        else
        {
            temp0 *= loinv;
            carry = RINT(temp0);
            x[k] = (temp0 -carry)* lo;
        }
        k++;
    }
    return(maxerr);
}

double lucas_square(double *x, UL N,UL iter, UL last,UL error_log,int *ip)
{
    unsigned i;
     double err;
#ifdef _MSC_VER
    double *c_maxerr = (double *)malloc(N / 512 * sizeof(double));
#else
    double c_maxerr[N/512];
#endif
    double bigAB=6755399441055744.0;

    rdft(N,x,ip);
    if( iter == last) 
    {
        cutilSafeCall(cudaMemcpy(x,g_x, sizeof(double)*N, cudaMemcpyDeviceToHost));
        err=last_normalize(x,N,error_log);
    } 
    else 
    {
        if ((iter % 10000) == 0) 
        {
            cutilSafeCall(cudaMemcpy(x,g_x, sizeof(double)*N, cudaMemcpyDeviceToHost));
            err=last_normalize(x,N,error_log);
        }

        dim3 grid(512 / BLOCK_DIM, 512 / BLOCK_DIM, 1);
        dim3 threads(BLOCK_DIM, BLOCK_DIM, 1);

        for(i=N;i>0;i-=(512*512))
            square_transpose<512><<< grid, threads >>>(&g_x[i],&g_x[i-512*512]);
	if (error_log) {
		normalize_kernel<1,512><<< N/512/128,128 >>>(&g_x[512*512],
				bigAB,bigAB,g_maxerr,g_carry,g_inv,g_ttp,g_ttmp);
	} else {
		normalize_kernel<0,512><<< N/512/128,128 >>>(&g_x[512*512],
				bigAB,bigAB,g_maxerr,g_carry,g_inv,g_ttp,g_ttmp);
	}
	normalize2_kernel<<< N/512/128,128 >>>(&g_x[512*512],
            bigAB,bigAB,g_maxerr,g_carry,N,g_inv,g_ttp,g_ttmp);
        for(i=(512*512);i<(N+512*512);i+=(512*512))
            square_transpose<512><<< grid, threads >>>(&g_x[i-512*512],&g_x[i]);
        
        err = 0.0;
        if(error_log)
        {
            cutilSafeCall(cudaMemcpy(c_maxerr,g_maxerr, sizeof(double)*N/512, cudaMemcpyDeviceToHost));
            for(i=0;i<(N/512);i++)
                if (c_maxerr[i]>err) err=c_maxerr[i];
        }
    }
#ifdef _MSC_VER
    free (c_maxerr);
#endif
    return(err);
}

/* This gives smallest power of two great or equal n */

UL power_of_two_length(UL n)
{
    UL i = (((UL)1) << 31), k = 32;
    do
    {
        k--;
        i >>= 1;
    } while ((i & n) == 0);
    return k;
}

/* Choose the lenght of FFT , n is the power of two preliminary solution,
N is the minimum required length, the return is the estimation of optimal 
lenght.

The estimation is made very rougly. I suposse a prime k pass cost about
k*lengthFFT cpu time (in some units)
*/
int choose_length(int n)
{
    UL bestN=1<<n;
    if (bestN < 524288)
        return(524288);
    return bestN;
}

void init_device()
{
    int device_count=0;
    struct cudaDeviceProp properties;

    cudaGetDeviceCount( &device_count);
    if (device_number >= device_count)
    {
        printf("device_number >=  device_count ... exiting\n");
        exit(2);
    }

#if CUDART_VERSION >= 4000
    cudaSetDeviceFlags(cudaDeviceScheduleBlockingSync);
    cudaDeviceSetCacheConfig(cudaFuncCachePreferL1);
#else
    cudaSetDeviceFlags(cudaDeviceBlockingSync);
#endif

    cudaSetDevice(device_number);
    // From Iain
    cudaGetDeviceProperties(&properties, device_number);

    if (properties.major == 1 && properties.minor < 3){
        printf("A GPU with compute capability >= 1.3 is required for double precision arithmetic\n");
        exit(2);
    }

}

/**************************************************************
*
*      Main Function
*
**************************************************************/

int main(int argc, char *argv[])
{
    UL q = 0L, n,  j = 1L, last = 2L, flag;
    size_t k;
    double err, *x =NULL;
    int restarting = 0;
    int *ip = NULL;
    char M = '\0';
    FILE *infp = NULL, *outfp = NULL, *dupfp = NULL;

    two_to_phi = NULL; 
    two_to_minusphi = NULL;

#if defined(__x86_64__)
    bigA=6755399441055744.0;
#else
    bigA=(((6.0)*0x2000000L)*0x2000000L)*0x800;
#endif
    bigB=bigA;

    g_x = NULL;

    UL averbits = (sizeof(double)*5)/2 - 1;

    strcpy(version, program_name);
    strcat(version, " v");
    strncat(version, program_revision + strlen("4Revision: "), strlen(program_revision) - strlen("4Revison:  4"));
    //strcat(version, " Ballester");
    setup();
    while (!shouldTerminate)
    {
        do /* while (restarting) */
        {
            switch ((restarting != 0) ? 3 : input(argc, argv, &q, &n, &j, &err, &x, last, &M, &infp, &outfp, &dupfp))
            {
            case 0: /* no more input */
                printf("no more input\n");
                return(0);

            case 1: /*something wrong; error message, if any, already printed */
            default:
                printf("something wrong; error message, if any, already printed\n");
                print_time();
                return(1);

            case 2: /* continuing work from a partial result */
                init_device(); //msft
                printf("continuing work from a partial result\n");
                restarting = 1; 
                /* not the usual sense of restarting (FFT errors too high) */
                /* size = n; */ /* supressed */

                break;

            case 3:
                init_device(); //msft
                n = (q-1)/averbits +1;
                j = power_of_two_length(n);
                n = choose_length(j);

                if (x != NULL) cutilSafeCall(cudaFreeHost((char *)x));
                cutilSafeCall(cudaMallocHost((void**) &x,(n+n)*sizeof(double)));
                for (k=1;k<n;k++) x[k]=0.0;
                x[0] = 4.0;
                j = 1;
                break;
            }
#ifdef _MSC_VER
            fflush (stdout);
#endif
            if (q <  216091) {
                printf(" too small Exponent\n");
                return 0;
            }
            if (two_to_phi != NULL) free((char *)two_to_phi);
            if (two_to_minusphi != NULL) free((char *)two_to_minusphi);

            if (!restarting)
            {
                if (M != 'U' && M != 'I' && last != q - 2)
                    (void)fprintf(stderr, "%s: exponent " PRINTF_FMT_UL " should not need Lucas-Lehmer testing\n", program_name, q);
                if ((M != 'U' && M != 'I') || last == q - 2)
                    continue;
            }
            restarting = 0;
            init_lucas(q, n);

            if (ip != NULL) free((char *)ip);
            ip = (int *)ALLOC_DOUBLES(((2+(size_t)sqrt((float)n/2))*sizeof(int)));
            ip[0]=0;

            if(j==1) x[0]*=two_to_minusphi[0]*n;
            last = q - 2; /* the last iteration done in the primary loop */
            int output_frequency = chkpnt_iterations ? chkpnt_iterations : 10000;
            for ( ; !shouldTerminate && !restarting && j <= last; j++)
            {
#if (kErrChkFreq > 1)
                if ((j % kErrChkFreq) == 1 || j < 1000)
#endif
                    flag = kErrChk;
#if (kErrChkFreq > 1)
                else 
                    flag = 0;
#endif
                err = lucas_square(x, n, j, last, flag,ip);
                if (chkpnt_iterations != 0 && j % chkpnt_iterations == 2 && j < last)
                {
                    cutilSafeCall(cudaMemcpy(x, g_x, sizeof(double)*n, cudaMemcpyDeviceToHost));
                    if(check_point(q, n, (UL) (j+1), err, x) < 0)
                    {
                        print_time();
                        return(errno);
                    }
                }
                if (err > kErrLimit) /* n is not big enough; increase it and start over */
                {
                    printf("err = %g, increasing n from %d\n",(double)err,(int)n);
                    averbits--;
                    restarting = 1;
                }
                if ((j % output_frequency) == 0) 
                { 
                    cutilSafeCall(cudaMemcpy(x,g_x, sizeof(double)*n, cudaMemcpyDeviceToHost));
					printbits(x, q, n, (q > 64L) ? 64L : q, b, c, high, low, version, outfp, dupfp, output_frequency, j);
                }
            }
            cufftSafeCall(cufftDestroy(plan));
            if (restarting) continue;
            else if (j < last) /* not done, but need to quit, for example, by a SIGTERM signal*/
            {
                chkpnt_iterations = 0L;

                cutilSafeCall(cudaMemcpy(x,g_x, sizeof(double)*n, cudaMemcpyDeviceToHost));

                return((check_point(q, n, j, err, x) <= 0) ? errno : 0);
            }
        } while (restarting);
        printbits(x, q, n, (q > 64L) ? 64L : q, b, c, high, low, version, outfp, dupfp, 0, j, true);
    }
    return(0);
}
