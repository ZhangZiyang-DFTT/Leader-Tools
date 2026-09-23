#include "LeaderTIFF.h"
#include <tiffio.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>

void lt_fill_v210(const float *rgba, void *destination, uint32_t width, uint32_t height, uint32_t row_bytes) {
    for (uint32_t y = 0; y < height; y++) {
        uint32_t *row = (uint32_t *)((unsigned char *)destination + (size_t)y * row_bytes);
        memset(row, 0, row_bytes);
        for (uint32_t x = 0; x < width; x += 6) {
            uint32_t luma[6], cb[3], cr[3];
            float u[6], v[6];
            for (uint32_t k = 0; k < 6; k++) {
                uint32_t px = x + k < width ? x + k : width - 1;
                const float *p = rgba + ((size_t)y * width + px) * 4;
                float r = fminf(1, fmaxf(0, p[0])), g = fminf(1, fmaxf(0, p[1]));
                float b = fminf(1, fmaxf(0, p[2]));
                float yy = 0.2126f * r + 0.7152f * g + 0.0722f * b;
                luma[k] = (uint32_t)lroundf(64 + 876 * yy);
                u[k] = (b - yy) / 1.8556f;
                v[k] = (r - yy) / 1.5748f;
            }
            for (uint32_t k = 0; k < 3; k++) {
                cb[k] = (uint32_t)lroundf(512 + 448 * (u[k * 2] + u[k * 2 + 1]));
                cr[k] = (uint32_t)lroundf(512 + 448 * (v[k * 2] + v[k * 2 + 1]));
            }
            row[0] = cb[0] | luma[0] << 10 | cr[0] << 20;
            row[1] = luma[1] | cb[1] << 10 | luma[2] << 20;
            row[2] = cr[1] | luma[3] << 10 | cb[2] << 20;
            row[3] = luma[4] | cr[2] << 10 | luma[5] << 20;
            row += 4;
        }
    }
}

int lt_write_tiff(const char *path, const float *rgba, uint32_t width,
                  uint32_t height, int bits, int video_range, int compressed,
                  const void *icc, uint32_t icc_size, const char *description) {
    if (!rgba || !width || !height || (bits != 10 && bits != 16)) return 0;
    TIFF *t = TIFFOpen(path, "wl");
    if (!t) return 0;
    int ok = TIFFSetField(t, TIFFTAG_IMAGEWIDTH, width)
        && TIFFSetField(t, TIFFTAG_IMAGELENGTH, height)
        && TIFFSetField(t, TIFFTAG_SAMPLESPERPIXEL, 3)
        && TIFFSetField(t, TIFFTAG_BITSPERSAMPLE, bits)
        && TIFFSetField(t, TIFFTAG_SAMPLEFORMAT, SAMPLEFORMAT_UINT)
        && TIFFSetField(t, TIFFTAG_PHOTOMETRIC, PHOTOMETRIC_RGB)
        && TIFFSetField(t, TIFFTAG_PLANARCONFIG, PLANARCONFIG_CONTIG)
        && TIFFSetField(t, TIFFTAG_ORIENTATION, ORIENTATION_TOPLEFT)
        && TIFFSetField(t, TIFFTAG_FILLORDER, FILLORDER_MSB2LSB)
        && TIFFSetField(t, TIFFTAG_ROWSPERSTRIP, 16)
        && TIFFSetField(t, TIFFTAG_COMPRESSION, compressed ? COMPRESSION_ADOBE_DEFLATE : COMPRESSION_NONE)
        && TIFFSetField(t, TIFFTAG_SOFTWARE, "Leader Tools 1.1.6 / LibTIFF")
        && TIFFSetField(t, TIFFTAG_IMAGEDESCRIPTION, description);
    if (compressed) ok = ok && TIFFSetField(t, TIFFTAG_ZIPQUALITY, 4);
    if (icc && icc_size) ok = ok && TIFFSetField(t, TIFFTAG_ICCPROFILE, icc_size, icc);
    tmsize_t size = TIFFScanlineSize(t);
    if (size <= 0) { TIFFClose(t); return 0; }
    unsigned char *row = calloc(1, (size_t)size);
    if (!row) ok = 0;
    for (uint32_t y = 0; ok && y < height; y++) {
        memset(row, 0, (size_t)size);
        uint64_t bit = 0;
        for (uint32_t x = 0; x < width; x++) {
            for (uint32_t c = 0; c < 3; c++) {
                float v = rgba[((size_t)y * width + x) * 4 + c];
                if (!isfinite(v)) v = 0;
                v = fminf(1, fmaxf(0, v));
                uint16_t q = (uint16_t)lroundf(video_range ? 64 + v * 876 : v * 1023);
                if (bits == 16) {
                    // RGB TIFF readers normalize by 65535, not by 65472.
                    // Preserve q/1023 for both ranges instead of left-aligning Q10.
                    ((uint16_t *)row)[x * 3 + c] = (uint16_t)(((uint32_t)q * 65535 + 511) / 1023);
                } else {
                    // TIFF packs arbitrary-width samples MSB-first and pads each row.
                    unsigned shift = 14 - (unsigned)(bit & 7);
                    uint32_t packed = (uint32_t)q << shift;
                    size_t b = (size_t)(bit >> 3);
                    row[b] |= (unsigned char)(packed >> 16);
                    row[b + 1] |= (unsigned char)(packed >> 8);
                    if (b + 2 < (size_t)size) row[b + 2] |= (unsigned char)packed;
                    bit += 10;
                }
            }
        }
        if (TIFFWriteScanline(t, row, y, 0) < 0) ok = 0;
    }
    if (ok) ok = TIFFWriteDirectory(t);
    free(row);
    TIFFClose(t);
    return ok;
}

int lt_check_tiff(const char *path, uint32_t *width, uint32_t *height,
                  uint16_t *bits, uint16_t *minimum, uint16_t *maximum,
                  uint32_t *unique_codes) {
    TIFF *t = TIFFOpen(path, "r");
    if (!t) return 0;
    uint16_t samples = 0, planar = 0, format = 0, photometric = 0;
    int ok = TIFFGetField(t, TIFFTAG_IMAGEWIDTH, width)
        && TIFFGetField(t, TIFFTAG_IMAGELENGTH, height)
        && TIFFGetField(t, TIFFTAG_BITSPERSAMPLE, bits)
        && TIFFGetField(t, TIFFTAG_SAMPLESPERPIXEL, &samples)
        && TIFFGetFieldDefaulted(t, TIFFTAG_PLANARCONFIG, &planar)
        && TIFFGetFieldDefaulted(t, TIFFTAG_SAMPLEFORMAT, &format)
        && TIFFGetField(t, TIFFTAG_PHOTOMETRIC, &photometric);
    tmsize_t row_size = TIFFScanlineSize(t);
    if (!ok || !*width || !*height || samples != 3 || (*bits != 10 && *bits != 16)
        || planar != PLANARCONFIG_CONTIG || format != SAMPLEFORMAT_UINT
        || photometric != PHOTOMETRIC_RGB || row_size <= 0
        || (uint64_t)row_size < ((uint64_t)*width * 3 * *bits + 7) / 8
        || row_size > 1 << 26) { TIFFClose(t); return 0; }
    unsigned char seen[65536] = {0};
    unsigned char *row = malloc((size_t)row_size);
    if (!row) { TIFFClose(t); return 0; }
    *minimum = 65535; *maximum = 0; *unique_codes = 0;
    for (uint32_t y = 0; ok && y < *height; y++) {
        if (TIFFReadScanline(t, row, y, 0) < 0) { ok = 0; break; }
        for (uint32_t s = 0; s < *width * 3; s++) {
            uint16_t v;
            if (*bits == 16) v = ((uint16_t *)row)[s];
            else {
                uint64_t bit = (uint64_t)s * 10;
                size_t b = (size_t)(bit >> 3);
                unsigned offset = bit & 7;
                v = (uint16_t)((((uint32_t)row[b] << 8) | row[b + 1]) >> (6 - offset)) & 1023;
            }
            if (!seen[v]) { seen[v] = 1; (*unique_codes)++; }
            if (v < *minimum) *minimum = v;
            if (v > *maximum) *maximum = v;
        }
    }
    free(row);
    TIFFClose(t);
    return ok;
}
