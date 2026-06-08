#include <stdio.h>
#include <math.h>
#include <stdlib.h>
typedef void (*mm)(const float*,const float*,float*,size_t,size_t,size_t);
extern void Naive_matmul(const float*,const float*,float*,size_t,size_t,size_t);
extern void Gemm_matmul(const float*,const float*,float*,size_t,size_t,size_t);
extern void Ikj_matmul(const float*,const float*,float*,size_t,size_t,size_t);
extern void Par_matmul(const float*,const float*,float*,size_t,size_t,size_t);
extern void Full_matmul(const float*,const float*,float*,size_t,size_t,size_t);
int main(void){
  int N=256; size_t n=N;
  static float a[256*256],b[256*256],y0[256*256],y[256*256];
  srand(1); for(int i=0;i<N*N;i++){ a[i]=(rand()%1000)/500.0f-1; b[i]=(rand()%1000)/500.0f-1; }
  Naive_matmul(a,b,y0,n,n,n);
  struct { const char*nm; mm f; int fma; } ks[]={{"Gemm",Gemm_matmul,0},{"Ikj",Ikj_matmul,0},{"Par",Par_matmul,0},{"Full",Full_matmul,1}};
  FILE*o=fopen("build/diff/d4.out","w");
  fprintf(o,"matmul %dx%d: each optimized kernel vs Naive reference\n",N,N);
  for(int t=0;t<4;t++){
    ks[t].f(a,b,y,n,n,n);
    double maxabs=0,maxrel=0; int exact=1;
    for(int i=0;i<N*N;i++){ double d=fabs(y[i]-y0[i]); if(d>0)exact=0; if(d>maxabs)maxabs=d;
      double r=d/(fabs(y0[i])+1e-30); if(r>maxrel)maxrel=r; }
    fprintf(o,"  %-5s %s  max|d|=%.2e maxrel=%.2e%s\n",ks[t].nm,
      exact?"BITWISE-EXACT":"approx      ",maxabs,maxrel,
      ks[t].fma?"  (@fp(contract): FMA traded by contract)":"");
  }
  fclose(o); return 0;
}
