// poc.c — the integration shape: call a Wyve kernel through Almide's
// AlmideMatrix::SmallF32 ABI (row-major f32), and benchmark it honestly
// against what Almide does today (hand ikj for tiny, Accelerate sgemm else).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <time.h>
#include <Accelerate/Accelerate.h>

// Almide's runtime variant, simplified: AlmideMatrix::SmallF32{rows,cols,data}
typedef struct { int rows, cols; float *data; } MatF32;   // row-major

// the Wyve kernel (examples/matmul.wyv, Full: @parallel+@interchange+@fp)
extern void Full_matmul(const float*, const float*, float*, size_t, size_t, size_t);

// the integration wrapper: AlmideMatrix in, AlmideMatrix out, Wyve inside
static MatF32 wyve_mul(const MatF32 *a, const MatF32 *b) {
    int m=a->rows, k=a->cols, n=b->cols;
    MatF32 c = { m, n, malloc((size_t)m*n*sizeof(float)) };
    Full_matmul(a->data, b->data, c.data, m, n, k);
    return c;
}
// Almide's tiny path (hand ikj + FMA), and its BLAS path
static void ikj(const MatF32*a,const MatF32*b,float*o){int m=a->rows,k=a->cols,n=b->cols;
  memset(o,0,(size_t)m*n*4); for(int i=0;i<m;i++)for(int p=0;p<k;p++){float aip=a->data[i*k+p];
    for(int j=0;j<n;j++)o[i*n+j]=fmaf(aip,b->data[p*n+j],o[i*n+j]);}}
static void blas(const MatF32*a,const MatF32*b,float*o){int m=a->rows,k=a->cols,n=b->cols;
  cblas_sgemm(101,111,111,m,n,k,1.0f,a->data,k,b->data,n,0.0f,o,n);}

static double ns(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec*1e9+t.tv_nsec;}
static volatile float sink;
int main(void){
  int sizes[]={16,64,256,512}; 
  printf("  N    Wyve(Full)   Almide-ikj   Accelerate-sgemm   (GFLOPS)\n");
  for(int si=0;si<4;si++){ int N=sizes[si];
    MatF32 a={N,N,malloc((size_t)N*N*4)}, b={N,N,malloc((size_t)N*N*4)};
    float *o=malloc((size_t)N*N*4);
    srand(1); for(int i=0;i<N*N;i++){a.data[i]=(rand()%200)/100.0f-1;b.data[i]=(rand()%200)/100.0f-1;}
    double flop=2.0*N*N*N;
    // correctness: wyve vs blas
    MatF32 cw=wyve_mul(&a,&b); blas(&a,&b,o);
    double maxrel=0; for(int i=0;i<N*N;i++){double d=fabs(cw.data[i]-o[i])/(fabs(o[i])+1e-6); if(d>maxrel)maxrel=d;}
    int reps = N<=64?20000:(N<=256?500:80);
    double bw=1e30; for(int r=0;r<5;r++){double t=ns();for(int q=0;q<reps;q++){MatF32 c=wyve_mul(&a,&b);sink=c.data[0];free(c.data);}double dt=(ns()-t)/reps;if(dt<bw)bw=dt;}
    double bi=1e30; for(int r=0;r<5;r++){double t=ns();for(int q=0;q<reps;q++){ikj(&a,&b,o);sink=o[0];}double dt=(ns()-t)/reps;if(dt<bi)bi=dt;}
    double bb=1e30; for(int r=0;r<5;r++){double t=ns();for(int q=0;q<reps;q++){blas(&a,&b,o);sink=o[0];}double dt=(ns()-t)/reps;if(dt<bb)bb=dt;}
    printf("%4d   %7.1f      %7.1f          %7.1f         (rel err %.1e)\n",
           N, flop/bw, flop/bi, flop/bb, maxrel);
    free(a.data);free(b.data);free(o);free(cw.data);
  }
  return 0;
}
