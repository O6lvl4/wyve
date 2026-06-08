#include <stddef.h>
extern void KERNEL(float, const float*, float*, unsigned long long);
static float xb[8192], yb[8192];
int main(void){
  unsigned long long n=8192; for(unsigned long long i=0;i<n;i++){xb[i]=i*1e-4f; yb[i]=1.0f;}
  volatile float s=0;
  for(int r=0;r<200000;r++){ KERNEL(0.5f, xb, yb, n); s+=yb[0]; if(yb[0]>1e30f) for(unsigned long long i=0;i<n;i++)yb[i]=1.0f; }
  return (int)s & 1;
}
