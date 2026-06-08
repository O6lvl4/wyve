#include <stddef.h>
void Naive_saxpy(float a, const float* x, float* y, unsigned long long n){
  for(unsigned long long i=0;i<n;i++) y[i]=a*x[i]+y[i];
}
