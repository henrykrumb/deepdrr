#include <stdio.h>
#include <cubicTex3D.cu>

#include "mat_coefs_for_kernel.cu"

#ifndef NUM_MATERIALS
#define NUM_MATERIALS 14
#endif

#define _seg(n) seg_##n
#define seg(n) _seg(n)

// channel of the materials array, same size as the volume.
#if NUM_MATERIALS > 0
texture<float, 3, cudaReadModeElementType> seg(0);
#endif
#if NUM_MATERIALS > 1
texture<float, 3, cudaReadModeElementType> seg(1);
#endif
#if NUM_MATERIALS > 2
texture<float, 3, cudaReadModeElementType> seg(2);
#endif
#if NUM_MATERIALS > 3
texture<float, 3, cudaReadModeElementType> seg(3);
#endif
#if NUM_MATERIALS > 4
texture<float, 3, cudaReadModeElementType> seg(4);
#endif
#if NUM_MATERIALS > 5
texture<float, 3, cudaReadModeElementType> seg(5);
#endif
#if NUM_MATERIALS > 6
texture<float, 3, cudaReadModeElementType> seg(6);
#endif
#if NUM_MATERIALS > 7
texture<float, 3, cudaReadModeElementType> seg(7);
#endif
#if NUM_MATERIALS > 8
texture<float, 3, cudaReadModeElementType> seg(8);
#endif
#if NUM_MATERIALS > 9
texture<float, 3, cudaReadModeElementType> seg(9);
#endif
#if NUM_MATERIALS > 10
texture<float, 3, cudaReadModeElementType> seg(10);
#endif
#if NUM_MATERIALS > 11
texture<float, 3, cudaReadModeElementType> seg(11);
#endif
#if NUM_MATERIALS > 12
texture<float, 3, cudaReadModeElementType> seg(12);
#endif
#if NUM_MATERIALS > 13
texture<float, 3, cudaReadModeElementType> seg(13);
#endif

#define UPDATE(multiplier, n) do {\
    output[idx + (n)] += (multiplier) * tex3D(volume, px, py, pz) * round(cubicTex3D(seg(n), px, py, pz));\
} while (0)

/*
 * I know this defintion of INTERPOLATE(...) is slower because of the for-loop operations, 
 * but while I'm working, I value the fact that it's compact in the file.  I can unroll the
 * loop when I have finished the other parts.
 */
#if (NUM_MATERIALS < 1) || (NUM_MATERIALS > 14)
#define INTERPOLATE(multiplier) do {\
    fprintf(stderr, "NUM_MATERIALS not in [1, 14]");\
} while (0)
#else
#define INTERPOLATE(multiplier) do {\
    for (int __mat = 0; __mat < NUM_MATERIALS; __mat++) {\
        UPDATE(multiplier, __mat);\
    }\
} while (0)

// the CT volume (used to be tex_density)
texture<float, 3, cudaReadModeElementType> volume;

extern "C" {
    __device__ float dev_1D_linear_log_interp(
        float xInterp,
        const int n_pts, // number of reference points
        const float *x, // reference x-values
        const float *y, // reference y-values
    ) {
        return; // TODO: implement
    }

    __device__ float dev_get_absorbtion_coefs(
        float energy, // the energy value on a spectrum
        int mat // the material 
    ) {
        xMev = energy / 1000;
        
        return; // TODO: implement
    }

    __global__  void projectKernel(
        int out_width, // width of the output image
        int out_height, // height of the output image
        float step,
        float gVolumeEdgeMinPointX,
        float gVolumeEdgeMinPointY,
        float gVolumeEdgeMinPointZ,
        float gVolumeEdgeMaxPointX,
        float gVolumeEdgeMaxPointY,
        float gVolumeEdgeMaxPointZ,
        float gVoxelElementSizeX,
        float gVoxelElementSizeY,
        float gVoxelElementSizeZ,
        float sx, // x-coordinate of source point for rays in world-space
        float sy,
        float sz,
        float *rt_kinv, // (3, 3) array giving the image-to-world-ray transform.
        float *output, // flat array, with shape (out_height, out_width, NUM_MATERIALS).
        float *intensity, // flat array, with shape (out_height, out_width).
        float *photon_prob, // flat array, with shape (out_height, out_width).
        const int n_bins, // the number of spectral bins
        const float *energies, // 1-D array -- size is the n_bins
        const float *pdf, // 1-D array -- probability density function over the energies
        const float *absorb_coef_table, // flat [n_bins x NUM_MATERIALS] table that represents
                        // the precomputed get_absorbtion_coef values.
                        // index into the table as: table[bin * NUM_MATERIALS + mat]
        int offsetW,
        int offsetH)
    {

        // The output image has the following coordinate system, with cell-centered sampling.
        // y is along the fast axis (columns), x along the slow (rows).
        // Each point has NUM_MATERIALS elements at it.
        // 
        //      x -->
        //    y *---------------------------*
        //    | |                           |
        //    V |                           |
        //      |        output image       |
        //      |                           |
        //      |                           |
        //      *---------------------------*
        // 
        //
        int udx = threadIdx.x + (blockIdx.x + offsetW) * blockDim.x; // index into output image width
        int vdx = threadIdx.y + (blockIdx.y + offsetH) * blockDim.y; // index into output image height

        // if the current point is outside the output image, no computation needed
        if (udx >= out_width || vdx >= out_height)
            return;

        // flat index to first material in output "channel". 
        // So (idx + m) gets you the pixel for material index m in [0, NUM_MATERIALS)
        int idx = udx * (out_height * NUM_MATERIALS) + vdx * NUM_MATERIALS; 

        // cell-centered sampling point corresponding to pixel index, in index-space.
        float u = (float) udx + 0.5;
        float v = (float) vdx + 0.5;

        // Vector in voxel-space along ray from source-point to pixel at [u,v] on the detector plane.
        float rx = u * rt_kinv[0] + v * rt_kinv[1] + rt_kinv[2];
        float ry = u * rt_kinv[3] + v * rt_kinv[4] + rt_kinv[5];
        float rz = u * rt_kinv[6] + v * rt_kinv[7] + rt_kinv[8];

        // make the ray a unit vector
        float normFactor = 1.0f / (sqrt((rx * rx) + (ry * ry) + (rz * rz)));
        rx *= normFactor;
        ry *= normFactor;
        rz *= normFactor;

        // calculate projections
        // Part 1: compute alpha value at entry and exit point of the volume on either side of the ray.
        // minAlpha: the distance from source point to volume entry point of the ray.
        // maxAlpha: the distance from source point to volume exit point of the ray.
        float minAlpha, maxAlpha;
        minAlpha = 0;
        maxAlpha = INFINITY;

        if (0.0f != rx)
        {
            float reci = 1.0f / rx;
            float alpha0 = (gVolumeEdgeMinPointX - sx) * reci;
            float alpha1 = (gVolumeEdgeMaxPointX - sx) * reci;
            minAlpha = fmin(alpha0, alpha1);
            maxAlpha = fmax(alpha0, alpha1);
        }
        else if (gVolumeEdgeMinPointX > sx || sx > gVolumeEdgeMaxPointX)
        {
            return;
        }

        if (0.0f != ry)
        {
            float reci = 1.0f / ry;
            float alpha0 = (gVolumeEdgeMinPointY - sy) * reci;
            float alpha1 = (gVolumeEdgeMaxPointY - sy) * reci;
            minAlpha = fmax(minAlpha, fmin(alpha0, alpha1));
            maxAlpha = fmin(maxAlpha, fmax(alpha0, alpha1));
        }
        else if (gVolumeEdgeMinPointY > sy || sy > gVolumeEdgeMaxPointY)
        {
            return;
        }

        if (0.0f != rz)
        {
            float reci = 1.0f / rz;
            float alpha0 = (gVolumeEdgeMinPointZ - sz) * reci;
            float alpha1 = (gVolumeEdgeMaxPointZ - sz) * reci;
            minAlpha = fmax(minAlpha, fmin(alpha0, alpha1));
            maxAlpha = fmin(maxAlpha, fmax(alpha0, alpha1));
        }
        else if (gVolumeEdgeMinPointZ > sz || sz > gVolumeEdgeMaxPointZ)
        {
            return;
        }

        // we start not at the exact entry point 
        // => we can be sure to be inside the volume
        // (this is commented out intentionally, seemingly)
        //minAlpha += step * 0.5f;
        
        // Part 2: Cast ray if it intersects the volume

        // Trapezoidal rule (interpolating function = piecewise linear func)
        float px, py, pz; // voxel-space point
        int t; // number of steps along ray
        float alpha; // distance along ray (alpha = minAlpha + step * t)
        float boundary_factor; // factor to multiply at the boundary.

        // initialize the output to 0.
        for (int m = 0; m < NUM_MATERIALS; m++) {
            output[idx + m] = 0;
        }

        // Sample the points along the ray at the entrance boundary of the volume and the mid segments.
        for (t = 0, alpha = minAlpha; alpha < maxAlpha; t++, alpha += step)
        {
            // Get the current sample point in the volume voxel-space.
            // In CUDA, voxel centeras are located at (xx.5, xx.5, xx.5), whereas SwVolume has voxel centers at integers.
            px = sx + alpha * rx + 0.5;
            py = sy + alpha * ry + 0.5;
            pz = sz + alpha * rz - gVolumeEdgeMinPointZ; // gVolumeEdgeMinPointZ == -0.5, per projector.py:Projector._project(...)

            /* For the entry boundary, multiply by 0.5 (this is the t == 0 check). That is, for the initial interpolated value, 
             * only a half step-size is considered in the computation.
             * For the second-to-last interpolation point, also multiply by 0.5, since there will be a final step at the maxAlpha boundary.
             */ 
            boundary_factor = (t == 0 || alpha + step >= maxAlpha) ? 0.5 : 1.0;

            // Perform the interpolation. This involves the variables: output, idx, px, py, pz, and volume. 
            // It is done for each segmentation.
            INTERPOLATE(boundary_factor);
        }

        // Scaling by step;
        output[idx] *= step;

        // Last segment of the line
        if (output[idx] > 0.0f) {
            alpha -= step;
            float lastStepsize = maxAlpha - alpha;

            // scaled last step interpolation (something weird?)
            INTERPOLATE(0.5 * lastStepsize);

            // The last segment of the line integral takes care of the varying length.
            px = sx + alpha * rx + 0.5;
            py = sy + alpha * ry + 0.5;
            pz = sz + alpha * rz - gVolumeEdgeMinPointZ;

            // interpolation
            INTERPOLATE(0.5 * lastStepsize);
        }

        // normalize output value to world coordinate system units
        for (int m = 0; m < NUM_MATERIALS; m++) {
            output[idx + m] *= sqrt((rx * gVoxelElementSizeX)*(rx * gVoxelElementSizeX) + (ry * gVoxelElementSizeY)*(ry * gVoxelElementSizeY) + (rz * gVoxelElementSizeZ)*(rz * gVoxelElementSizeZ));
        }

        /* Up to this point, we have accomplished the original projectKernel functionality.
         * The next steps to do are combining the forward_projections dictionary-ization and 
         * the mass_attenuation computation
         */

        // forward_projections dictionary-ization is implicit.

        // zero-out intensity and photon_prob
        intensity[idx] = 0;
        photon_prob[idx] = 0;

        // MASS ATTENUATION COMPUTATION
        for (int bin = 0; bin < n_bins; bin++) {
            float energy = energies[bin];
            float p = pdf[bin];

            float intensity_tmp = 0.0f; // lifting the call to calculate_attenuation_gpu(...) up a level
            for (int m = 0; m < NUM_MATERIALS; m++) {
                intensity_tmp += output[idx + m] * -1 * dev_get_absorbtion_coefs(energy, m);
            }
            intensity_tmp = exp10f(intensity_tmp) * energy * p; // TODO: check whether this is the proper base for the exponential function
            // done with the "lifted" call to calculate_attenuation_gpu(...)

            intensity[idx] += intensity_tmp;
            photon_prob[idx] += intensity_tmp / energies[bin];
        }

        return;
    }
}
    
