/*
 * Native file reading for the moonflow CLI.
 *
 * argv plumbing only: the CLI opens the model file the user named and hands the
 * bytes to PureEngine. The pipeline's own file tools sandbox paths; this does
 * not, because the path came from the command line, not from model output.
 *
 * Symbols are mf_* to avoid clashes with ef_* (source), ex_* (example) and
 * moonlm's ml_* when several packages land in one workspace link.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <moonbit.h>

MOONBIT_FFI_EXPORT
void *mf_fopen(const char *path, const char *mode) {
  return fopen(path, mode);
}

MOONBIT_FFI_EXPORT
int32_t mf_is_null(void *ptr) {
  return ptr == 0;
}

MOONBIT_FFI_EXPORT
int32_t mf_fclose(void *handle) {
  return fclose((FILE *)handle);
}

MOONBIT_FFI_EXPORT
int64_t mf_size(void *handle) {
  FILE *f = (FILE *)handle;
  if (fseek(f, 0, SEEK_END) != 0) {
    return -1;
  }
  long n = ftell(f);
  if (n < 0) {
    return -1;
  }
  if (fseek(f, 0, SEEK_SET) != 0) {
    return -1;
  }
  return (int64_t)n;
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t mf_read_owned(void *handle, int64_t n) {
  FILE *f = (FILE *)handle;
  if (fseek(f, 0, SEEK_SET) != 0) {
    return moonbit_make_bytes_raw(0);
  }
  moonbit_bytes_t buf = moonbit_make_bytes_raw((int32_t)n);
  size_t got = fread(buf, 1, (size_t)n, f);
  if ((int64_t)got != n) {
    return moonbit_make_bytes_raw(0);
  }
  return buf;
}

/* The process exit is routed through C for the same reason as moonlm's CLI:
 * `exit` is a native-only symbol, kept out of the MoonBit surface. */
MOONBIT_FFI_EXPORT
void mf_exit(int32_t code) {
  exit(code);
}
