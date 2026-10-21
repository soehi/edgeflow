/*
 * Native filesystem access for edgeflow's source package.
 *
 * The same envelope discipline as moonlm's tool stubs: failures carry a
 * one-byte status (0 ok, 1 error) and a UTF-8 message, read back via
 * ef_last_error; the numeric queries return a negative value. Nothing opens a
 * file for writing.
 *
 * ef_read_bytes returns the RAW bytes (not decoded text) so the MoonBit side can
 * decide whether the file is valid UTF-8 and tag it accordingly — the C layer
 * does not second-guess encoding.
 *
 * Symbols are ef_* to avoid clashing with the ml_* (moonlm) and ex_*
 * (examples) stubs that can end up in the same workspace link.
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/stat.h>
#include <moonbit.h>

#ifdef _WIN32
#include <windows.h>
#include <wchar.h>
#else
#include <dirent.h>
#include <unistd.h>
#endif

static char ef_error_text[1024];

static void ef_set_errno_error(const char *what) {
  int e = errno;
  snprintf(ef_error_text, sizeof ef_error_text, "%s: errno %d (%s)", what, e,
           strerror(e));
}

#ifdef _WIN32
static void ef_set_win32_error(const char *what) {
  DWORD code = GetLastError();
  wchar_t wbuf[512];
  DWORD n = FormatMessageW(
      FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL, code,
      MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT), wbuf, 512, NULL);
  while (n > 0 && (wbuf[n - 1] == L'\r' || wbuf[n - 1] == L'\n')) {
    wbuf[--n] = L'\0';
  }
  char ubuf[768];
  ubuf[0] = '\0';
  if (n > 0) {
    WideCharToMultiByte(CP_UTF8, 0, wbuf, -1, ubuf, (int)sizeof ubuf, NULL, NULL);
  }
  snprintf(ef_error_text, sizeof ef_error_text, "%s: win32 error %lu (%s)",
           what, (unsigned long)code, ubuf);
}

static wchar_t *ef_utf8_to_wide(const char *s) {
  int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, NULL, 0);
  if (n <= 0) {
    return NULL;
  }
  wchar_t *w = (wchar_t *)malloc((size_t)n * sizeof(wchar_t));
  if (w == NULL) {
    SetLastError(ERROR_NOT_ENOUGH_MEMORY);
    return NULL;
  }
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, w, n) <= 0) {
    free(w);
    return NULL;
  }
  return w;
}

static char *ef_wide_to_utf8(const wchar_t *w) {
  int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
  if (n <= 0) {
    return NULL;
  }
  char *s = (char *)malloc((size_t)n);
  if (s == NULL) {
    return NULL;
  }
  if (WideCharToMultiByte(CP_UTF8, 0, w, -1, s, n, NULL, NULL) <= 0) {
    free(s);
    return NULL;
  }
  return s;
}

static void ef_normalize_final_path(wchar_t *w) {
  if (wcsncmp(w, L"\\\\?\\UNC\\", 8) == 0) {
    size_t rest = wcslen(w + 8);
    memmove(w + 2, w + 8, (rest + 1) * sizeof(wchar_t));
    w[0] = L'\\';
    w[1] = L'\\';
  } else if (wcsncmp(w, L"\\\\?\\", 4) == 0) {
    size_t rest = wcslen(w + 4);
    memmove(w, w + 4, (rest + 1) * sizeof(wchar_t));
  }
  for (wchar_t *p = w; *p; ++p) {
    if (*p == L'/') {
      *p = L'\\';
    }
  }
}
#endif /* _WIN32 */

static moonbit_bytes_t ef_envelope(int status, const void *payload, size_t len) {
  if (len > 0x7FFFFFFE) {
    len = 0;
  }
  moonbit_bytes_t b = moonbit_make_bytes_raw((int32_t)(1 + len));
  b[0] = (uint8_t)status;
  if (len > 0 && payload != NULL) {
    memcpy(b + 1, payload, len);
  }
  return b;
}

static moonbit_bytes_t ef_envelope_str(const char *s) {
  return ef_envelope(0, s, s ? strlen(s) : 0);
}

static moonbit_bytes_t ef_envelope_error(void) {
  return ef_envelope(1, ef_error_text, strlen(ef_error_text));
}

MOONBIT_FFI_EXPORT
int32_t ef_is_windows(void) {
#ifdef _WIN32
  return 1;
#else
  return 0;
#endif
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t ef_last_error(void) {
  return ef_envelope_str(ef_error_text);
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t ef_realpath(const char *path) {
#ifdef _WIN32
  wchar_t *w = ef_utf8_to_wide(path);
  if (w == NULL) {
    ef_set_win32_error("realpath");
    return ef_envelope_error();
  }
  HANDLE h = CreateFileW(
      w, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL,
      OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
  free(w);
  if (h == INVALID_HANDLE_VALUE) {
    ef_set_win32_error("realpath");
    return ef_envelope_error();
  }
  DWORD need = GetFinalPathNameByHandleW(
      h, NULL, 0, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  if (need == 0) {
    CloseHandle(h);
    ef_set_win32_error("realpath");
    return ef_envelope_error();
  }
  wchar_t *out = (wchar_t *)malloc(((size_t)need + 1) * sizeof(wchar_t));
  if (out == NULL) {
    CloseHandle(h);
    SetLastError(ERROR_NOT_ENOUGH_MEMORY);
    ef_set_win32_error("realpath");
    return ef_envelope_error();
  }
  DWORD got = GetFinalPathNameByHandleW(
      h, out, need + 1, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
  CloseHandle(h);
  if (got == 0 || got > need) {
    free(out);
    ef_set_win32_error("realpath");
    return ef_envelope_error();
  }
  ef_normalize_final_path(out);
  char *u = ef_wide_to_utf8(out);
  free(out);
  if (u == NULL) {
    ef_set_win32_error("realpath");
    return ef_envelope_error();
  }
  moonbit_bytes_t r = ef_envelope_str(u);
  free(u);
  return r;
#else
  char *resolved = realpath(path, NULL);
  if (resolved == NULL) {
    ef_set_errno_error("realpath");
    return ef_envelope_error();
  }
  moonbit_bytes_t r = ef_envelope_str(resolved);
  free(resolved);
  return r;
#endif
}

MOONBIT_FFI_EXPORT
moonbit_bytes_t ef_list_dir(const char *path) {
#ifdef _WIN32
  wchar_t *w = ef_utf8_to_wide(path);
  if (w == NULL) {
    ef_set_win32_error("list_dir");
    return ef_envelope_error();
  }
  size_t n = wcslen(w);
  wchar_t *pattern = (wchar_t *)malloc((n + 3) * sizeof(wchar_t));
  if (pattern == NULL) {
    free(w);
    SetLastError(ERROR_NOT_ENOUGH_MEMORY);
    ef_set_win32_error("list_dir");
    return ef_envelope_error();
  }
  memcpy(pattern, w, n * sizeof(wchar_t));
  pattern[n] = L'\\';
  pattern[n + 1] = L'*';
  pattern[n + 2] = L'\0';
  free(w);
  WIN32_FIND_DATAW fd;
  HANDLE h = FindFirstFileW(pattern, &fd);
  free(pattern);
  if (h == INVALID_HANDLE_VALUE) {
    ef_set_win32_error("list_dir");
    return ef_envelope_error();
  }
  size_t cap = 256, len = 0;
  char *buf = (char *)malloc(cap);
  if (buf == NULL) {
    FindClose(h);
    SetLastError(ERROR_NOT_ENOUGH_MEMORY);
    ef_set_win32_error("list_dir");
    return ef_envelope_error();
  }
  int rc = 0;
  do {
    if (wcscmp(fd.cFileName, L".") == 0 || wcscmp(fd.cFileName, L"..") == 0) {
      continue;
    }
    char *u = ef_wide_to_utf8(fd.cFileName);
    if (u == NULL) {
      rc = -1;
      break;
    }
    size_t ul = strlen(u);
    if (len + ul + 2 > cap) {
      while (len + ul + 2 > cap) {
        cap *= 2;
      }
      char *grown = (char *)realloc(buf, cap);
      if (grown == NULL) {
        free(u);
        rc = -2;
        break;
      }
      buf = grown;
    }
    if (len > 0) {
      buf[len++] = '\n';
    }
    memcpy(buf + len, u, ul);
    len += ul;
    free(u);
  } while (FindNextFileW(h, &fd));
  DWORD last = GetLastError();
  FindClose(h);
  if (rc != 0) {
    free(buf);
    SetLastError(rc == -2 ? ERROR_NOT_ENOUGH_MEMORY : last);
    ef_set_win32_error("list_dir");
    return ef_envelope_error();
  }
  if (last != ERROR_NO_MORE_FILES) {
    free(buf);
    SetLastError(last);
    ef_set_win32_error("list_dir");
    return ef_envelope_error();
  }
  moonbit_bytes_t r = ef_envelope(0, buf, len);
  free(buf);
  return r;
#else
  DIR *d = opendir(path);
  if (d == NULL) {
    ef_set_errno_error("list_dir");
    return ef_envelope_error();
  }
  size_t cap = 256, len = 0;
  char *buf = (char *)malloc(cap);
  if (buf == NULL) {
    closedir(d);
    snprintf(ef_error_text, sizeof ef_error_text, "list_dir: out of memory");
    return ef_envelope_error();
  }
  int failed = 0;
  struct dirent *e;
  errno = 0;
  while ((e = readdir(d)) != NULL) {
    if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0) {
      continue;
    }
    size_t ul = strlen(e->d_name);
    if (len + ul + 2 > cap) {
      while (len + ul + 2 > cap) {
        cap *= 2;
      }
      char *grown = (char *)realloc(buf, cap);
      if (grown == NULL) {
        failed = -1;
        break;
      }
      buf = grown;
    }
    if (len > 0) {
      buf[len++] = '\n';
    }
    memcpy(buf + len, e->d_name, ul);
    len += ul;
  }
  int saved = errno;
  closedir(d);
  if (failed != 0) {
    free(buf);
    snprintf(ef_error_text, sizeof ef_error_text, "list_dir: out of memory");
    return ef_envelope_error();
  }
  if (saved != 0) {
    free(buf);
    errno = saved;
    ef_set_errno_error("list_dir");
    return ef_envelope_error();
  }
  moonbit_bytes_t r = ef_envelope(0, buf, len);
  free(buf);
  return r;
#endif
}

MOONBIT_FFI_EXPORT
int64_t ef_stat_size(const char *path) {
#ifdef _WIN32
  wchar_t *w = ef_utf8_to_wide(path);
  if (w == NULL) {
    ef_set_win32_error("stat_size");
    return -1;
  }
  struct _stat64 st;
  int rc = _wstat64(w, &st);
  free(w);
  if (rc != 0) {
    ef_set_errno_error("stat_size");
    return -1;
  }
  return (int64_t)st.st_size;
#else
  struct stat st;
  if (stat(path, &st) != 0) {
    ef_set_errno_error("stat_size");
    return -1;
  }
  return (int64_t)st.st_size;
#endif
}

MOONBIT_FFI_EXPORT
int32_t ef_is_dir(const char *path) {
#ifdef _WIN32
  wchar_t *w = ef_utf8_to_wide(path);
  if (w == NULL) {
    ef_set_win32_error("is_dir");
    return -1;
  }
  struct _stat64 st;
  int rc = _wstat64(w, &st);
  free(w);
  if (rc != 0) {
    ef_set_errno_error("is_dir");
    return -1;
  }
  return (st.st_mode & _S_IFDIR) != 0 ? 1 : 0;
#else
  struct stat st;
  if (stat(path, &st) != 0) {
    ef_set_errno_error("is_dir");
    return -1;
  }
  return S_ISDIR(st.st_mode) ? 1 : 0;
#endif
}

/* Read up to `max_bytes` of a file as RAW bytes, no decoding. Returns an
 * envelope whose payload is the file bytes (valid UTF-8 or not — the MoonBit
 * side decides how to interpret them). A file larger than max_bytes is an
 * error, not a truncation, so a source never silently hands over half a file. */
MOONBIT_FFI_EXPORT
moonbit_bytes_t ef_read_bytes(const char *path, int64_t max_bytes) {
  int64_t size = ef_stat_size(path);
  if (size < 0) {
    return ef_envelope_error();
  }
  if (size > max_bytes) {
    snprintf(ef_error_text, sizeof ef_error_text,
             "file is %lld bytes, over the %lld-byte cap",
             (long long)size, (long long)max_bytes);
    return ef_envelope_error();
  }
  if (size > 0x7FFFFFFF) {
    snprintf(ef_error_text, sizeof ef_error_text,
             "file too large for a 32-bit buffer");
    return ef_envelope_error();
  }
#ifdef _WIN32
  wchar_t *w = ef_utf8_to_wide(path);
  if (w == NULL) {
    ef_set_win32_error("read");
    return ef_envelope_error();
  }
  FILE *f = _wfopen(w, L"rb");
  free(w);
#else
  FILE *f = fopen(path, "rb");
#endif
  if (f == NULL) {
    ef_set_errno_error("read");
    return ef_envelope_error();
  }
  moonbit_bytes_t raw = moonbit_make_bytes_raw((int32_t)size);
  size_t got = fread(raw, 1, (size_t)size, f);
  int read_err = ferror(f);
  fclose(f);
  if (read_err || (int64_t)got != size) {
    if (read_err) {
      ef_set_errno_error("read");
    } else {
      snprintf(ef_error_text, sizeof ef_error_text,
               "short read: %lld of %lld bytes", (long long)got,
               (long long)size);
    }
    return ef_envelope_error();
  }
  return ef_envelope(0, raw, (size_t)size);
}

/*
 * Test fixture: a temporary tree for the source tests.
 *
 *   <root>/ws/inside.txt          "hello"
 *   <root>/ws/sub/nested.txt      "nested"
 *   <root>/ws/binary.bin          invalid UTF-8 bytes (FF FE 'x')
 *   <root>/ws/escape -> <root>/outside      (symlink pointing out)
 *   <root>/outside/secret.txt     "secret"
 *   <root>/big/big.txt            262145 'x' bytes (just over the 256 KB cap)
 *
 * Returns the canonical root, or an error envelope. Tests only, like the
 * sandbox fixture in moonlm: nothing in the library calls it, and it does not
 * weaken the read-only guarantee of the library entry points.
 */
MOONBIT_FFI_EXPORT
moonbit_bytes_t ef_test_make_tree(void) {
#ifdef _WIN32
  wchar_t tmp[512];
  DWORD tn = GetTempPathW(512, tmp);
  if (tn == 0 || tn >= 512) {
    ef_set_win32_error("make_tree");
    return ef_envelope_error();
  }
  wchar_t root[768];
  int made = 0;
  for (int attempt = 0; attempt < 64; ++attempt) {
    _snwprintf_s(root, 768, _TRUNCATE, L"%seflow-source-%lu-%d", tmp,
                 (unsigned long)GetCurrentProcessId(), attempt);
    if (CreateDirectoryW(root, NULL)) {
      made = 1;
      break;
    }
    if (GetLastError() != ERROR_ALREADY_EXISTS) {
      ef_set_win32_error("make_tree");
      return ef_envelope_error();
    }
  }
  if (!made) {
    snprintf(ef_error_text, sizeof ef_error_text,
             "make_tree: no temporary directory");
    return ef_envelope_error();
  }
  wchar_t ws[900], sub[900], outside[900], big[900], path[900], link[900];
  _snwprintf_s(ws, 900, _TRUNCATE, L"%s\\ws", root);
  _snwprintf_s(sub, 900, _TRUNCATE, L"%s\\sub", ws);
  _snwprintf_s(outside, 900, _TRUNCATE, L"%s\\outside", root);
  _snwprintf_s(big, 900, _TRUNCATE, L"%s\\big", root);
  if (!CreateDirectoryW(ws, NULL) || !CreateDirectoryW(sub, NULL) ||
      !CreateDirectoryW(outside, NULL) || !CreateDirectoryW(big, NULL)) {
    ef_set_win32_error("make_tree");
    return ef_envelope_error();
  }
  FILE *f;
  _snwprintf_s(path, 900, _TRUNCATE, L"%s\\inside.txt", ws);
  f = _wfopen(path, L"wb");
  if (!f) { ef_set_errno_error("make_tree"); return ef_envelope_error(); }
  fputs("hello", f);
  fclose(f);
  _snwprintf_s(path, 900, _TRUNCATE, L"%s\\nested.txt", sub);
  f = _wfopen(path, L"wb");
  if (!f) { ef_set_errno_error("make_tree"); return ef_envelope_error(); }
  fputs("nested", f);
  fclose(f);
  _snwprintf_s(path, 900, _TRUNCATE, L"%s\\binary.bin", ws);
  f = _wfopen(path, L"wb");
  if (!f) { ef_set_errno_error("make_tree"); return ef_envelope_error(); }
  {
    unsigned char junk[3] = { 0xFF, 0xFE, 'x' };
    fwrite(junk, 1, 3, f);
  }
  fclose(f);
  _snwprintf_s(path, 900, _TRUNCATE, L"%s\\secret.txt", outside);
  f = _wfopen(path, L"wb");
  if (!f) { ef_set_errno_error("make_tree"); return ef_envelope_error(); }
  fputs("secret", f);
  fclose(f);
  _snwprintf_s(path, 900, _TRUNCATE, L"%s\\big.txt", big);
  f = _wfopen(path, L"wb");
  if (!f) { ef_set_errno_error("make_tree"); return ef_envelope_error(); }
  {
    static char xs[262145];
    memset(xs, 'x', 262144);
    xs[262144] = '\0';
    fwrite(xs, 1, 262145, f);
  }
  fclose(f);
  _snwprintf_s(link, 900, _TRUNCATE, L"%s\\escape", ws);
  DWORD flags = SYMBOLIC_LINK_FLAG_DIRECTORY | 0x2;
  if (!CreateSymbolicLinkW(link, outside, flags)) {
    DWORD err = GetLastError();
    if (err == ERROR_INVALID_PARAMETER) {
      if (!CreateSymbolicLinkW(link, outside, SYMBOLIC_LINK_FLAG_DIRECTORY)) {
        ef_set_win32_error("make_tree (symlink)");
        return ef_envelope_error();
      }
    } else {
      SetLastError(err);
      ef_set_win32_error("make_tree (symlink)");
      return ef_envelope_error();
    }
  }
  char *u = ef_wide_to_utf8(root);
  if (u == NULL) {
    ef_set_win32_error("make_tree");
    return ef_envelope_error();
  }
  moonbit_bytes_t canon = ef_realpath(u);
  free(u);
  return canon;
#else
  char tmpl[] = "/tmp/eflow-source-XXXXXX";
  char *root = mkdtemp(tmpl);
  if (root == NULL) {
    ef_set_errno_error("make_tree");
    return ef_envelope_error();
  }
  char ws[512], sub[512], outside[512], big[512], path[512], link[512];
  snprintf(ws, sizeof ws, "%s/ws", root);
  snprintf(sub, sizeof sub, "%s/sub", ws);
  snprintf(outside, sizeof outside, "%s/outside", root);
  snprintf(big, sizeof big, "%s/big", root);
  if (mkdir(ws, 0755) || mkdir(sub, 0755) || mkdir(outside, 0755) ||
      mkdir(big, 0755)) {
    ef_set_errno_error("make_tree");
    return ef_envelope_error();
  }
  FILE *f;
  snprintf(path, sizeof path, "%s/inside.txt", ws);
  f = fopen(path, "wb");
  if (!f) { ef_set_errno_error("make_tree"); return ef_envelope_error(); }
  fputs("hello", f);
  fclose(f);
  snprintf(path, sizeof path, "%s/nested.txt", sub);
  f = fopen(path, "wb");
  if (!f) { ef_set_errno_error("make_tree"); return ef_envelope_error(); }
  fputs("nested", f);
  fclose(f);
  snprintf(path, sizeof path, "%s/binary.bin", ws);
  f = fopen(path, "wb");
  if (!f) { ef_set_errno_error("make_tree"); return ef_envelope_error(); }
  {
    unsigned char junk[3] = { 0xFF, 0xFE, 'x' };
    fwrite(junk, 1, 3, f);
  }
  fclose(f);
  snprintf(path, sizeof path, "%s/secret.txt", outside);
  f = fopen(path, "wb");
  if (!f) { ef_set_errno_error("make_tree"); return ef_envelope_error(); }
  fputs("secret", f);
  fclose(f);
  snprintf(path, sizeof path, "%s/big.txt", big);
  f = fopen(path, "wb");
  if (!f) { ef_set_errno_error("make_tree"); return ef_envelope_error(); }
  {
    static char xs[262145];
    memset(xs, 'x', 262144);
    xs[262144] = '\0';
    fwrite(xs, 1, 262145, f);
  }
  fclose(f);
  snprintf(link, sizeof link, "%s/escape", ws);
  if (symlink(outside, link) != 0) {
    ef_set_errno_error("make_tree (symlink)");
    return ef_envelope_error();
  }
  return ef_realpath(root);
#endif
}
