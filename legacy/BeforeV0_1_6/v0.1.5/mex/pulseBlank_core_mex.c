/*
 * pulseBlank_core_mex.c — P1 pulse blanker core
 *
 * [y, ppre_dB, ppost_dB, eta] = pulseBlank_core_mex(x, threshold)
 * x: complex double vector; samples with |x| > threshold zeroed.
 *
 * Build: mex -O mex/pulseBlank_core_mex.c -output mex/pulseBlank_core_mex
 */

#include "mex.h"
#include "matrix.h"
#include <math.h>

void mexFunction(int nlhs, mxArray *plhs[], int nrhs, const mxArray *prhs[])
{
    if (nrhs != 2)
        mexErrMsgIdAndTxt("pulseBlank:nrhs", "Need x, threshold");
    if (!mxIsDouble(prhs[0]) || !mxIsComplex(prhs[0]))
        mexErrMsgIdAndTxt("pulseBlank:x", "x must be complex double");
    if (!mxIsDouble(prhs[1]) || mxIsComplex(prhs[1]) || mxGetNumberOfElements(prhs[1]) != 1)
        mexErrMsgIdAndTxt("pulseBlank:th", "threshold must be real scalar");

    mwSize n = mxGetNumberOfElements(prhs[0]);
    mxComplexDouble *xin = mxGetComplexDoubles(prhs[0]);
    double th = mxGetScalar(prhs[1]);
    double th2 = th * th;

    plhs[0] = mxCreateDoubleMatrix(mxGetM(prhs[0]), mxGetN(prhs[0]), mxCOMPLEX);
    mxComplexDouble *xout = mxGetComplexDoubles(plhs[0]);

    double sumPre = 0.0, sumPost = 0.0;
    mwSize nBlank = 0;

    for (mwSize i = 0; i < n; ++i) {
        double re = xin[i].real;
        double im = xin[i].imag;
        double a2 = re*re + im*im;
        sumPre += a2;
        if (a2 > th2) {
            xout[i].real = 0.0;
            xout[i].imag = 0.0;
            nBlank++;
            /* post power contribution 0 */
        } else {
            xout[i].real = re;
            xout[i].imag = im;
            sumPost += a2;
        }
    }

    double invN = (n > 0) ? (1.0 / (double)n) : 0.0;
    double ppre  = 10.0 * log10(sumPre * invN + 1e-30);
    double ppost = 10.0 * log10(sumPost * invN + 1e-30);
    double eta   = (double)nBlank * invN;

    if (nlhs > 1) plhs[1] = mxCreateDoubleScalar(ppre);
    if (nlhs > 2) plhs[2] = mxCreateDoubleScalar(ppost);
    if (nlhs > 3) plhs[3] = mxCreateDoubleScalar(eta);
}
