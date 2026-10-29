// Copyright 2026 RunLedger contributors
// SPDX-License-Identifier: Apache-2.0
// POSIX byte-stream and atomic-file adapters. Audit/sort policy lives in MoonBit.
#define _DARWIN_C_SOURCE
#define _DEFAULT_SOURCE
#define _FILE_OFFSET_BITS 64
#define _POSIX_C_SOURCE 200809L
#include "moonbit.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#ifndef _WIN32
#include <sys/stat.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#endif

typedef struct { FILE *file; int status; } rl_stream;
static rl_stream *rl_wrap(FILE *f) {
  if (!f) return NULL;
  rl_stream *s = malloc(sizeof(*s));
  if (!s) { fclose(f); errno=ENOMEM; return NULL; }
  s->file=f; s->status=0; return s;
}
MOONBIT_FFI_EXPORT rl_stream *rl_open(moonbit_bytes_t path, int write) {
#ifndef _WIN32
  int fd=open((const char *)path, write ? O_WRONLY|O_CREAT|O_TRUNC|O_NOFOLLOW : O_RDONLY|O_NOFOLLOW, 0600);
  if (fd<0) return NULL;
  FILE *f=fdopen(fd, write ? "wb" : "rb");
  if (!f) { close(fd); return NULL; }
  return rl_wrap(f);
#else
  (void)path; (void)write; errno=ENOSYS; return NULL;
#endif
}
MOONBIT_FFI_EXPORT int rl_null(void *s) { return s==NULL; }
MOONBIT_FFI_EXPORT int rl_close(rl_stream *s) {
  if (!s) return 0;
  int r=fclose(s->file); free(s); return r;
}
MOONBIT_FFI_EXPORT int rl_sync(rl_stream *s) {
#ifndef _WIN32
  if (fflush(s->file)) return -1;
  return fsync(fileno(s->file));
#else
  (void)s; return -1;
#endif
}
// status: 0 EOF, 1 line (including an empty line), 2 oversized line, -1 I/O error.
MOONBIT_FFI_EXPORT moonbit_bytes_t rl_line(rl_stream *s, int limit) {
  size_t len=0, cap=256; if ((size_t)limit<cap) cap=(size_t)limit;
  unsigned char *buf=malloc(cap ? cap : 1); int c, seen=0, too_long=0;
  if (!buf) { s->status=-1; return moonbit_make_bytes(0,0); }
  while ((c=getc(s->file))!=EOF) {
    seen=1; if (c=='\n') break;
    if (len==(size_t)limit) { too_long=1; continue; }
    if (len==cap) {
      size_t next=cap*2; if (next>(size_t)limit) next=(size_t)limit;
      void *p=realloc(buf,next); if (!p) { free(buf); s->status=-1; return moonbit_make_bytes(0,0); }
      buf=p; cap=next;
    }
    if (!too_long) buf[len++]=(unsigned char)c;
  }
  s->status=ferror(s->file) ? -1 : too_long ? 2 : seen ? 1 : 0;
  moonbit_bytes_t result=moonbit_make_bytes(s->status==1 ? (int)len : 0,0);
  if (s->status==1 && len) memcpy(result,buf,len);
  free(buf); return result;
}
MOONBIT_FFI_EXPORT int rl_status(rl_stream *s) { return s->status; }
MOONBIT_FFI_EXPORT int64_t rl_tell(rl_stream *s) {
#ifndef _WIN32
  return (int64_t)ftello(s->file);
#else
  return -1;
#endif
}
MOONBIT_FFI_EXPORT int rl_seek(rl_stream *s, int64_t off) {
#ifndef _WIN32
  return fseeko(s->file,(off_t)off,SEEK_SET);
#else
  return -1;
#endif
}
MOONBIT_FFI_EXPORT int rl_write(rl_stream *s, moonbit_bytes_t bytes) {
  size_t n=(size_t)Moonbit_array_length(bytes);
  return fwrite(bytes,1,n,s->file)==n ? 0 : -1;
}
MOONBIT_FFI_EXPORT int rl_mkdir(moonbit_bytes_t path) {
#ifndef _WIN32
  return mkdir((const char *)path,0700);
#else
  return -1;
#endif
}
MOONBIT_FFI_EXPORT int rl_private_dir(moonbit_bytes_t path) {
#ifndef _WIN32
  struct stat s;
  return lstat((const char *)path,&s)==0 && S_ISDIR(s.st_mode) && s.st_uid==getuid() && (s.st_mode&077)==0;
#else
  return 0;
#endif
}
MOONBIT_FFI_EXPORT rl_stream *rl_lock(moonbit_bytes_t path) {
#ifndef _WIN32
  int fd=open((const char *)path,O_RDWR|O_CREAT|O_NOFOLLOW,0600);
  if (fd<0) return NULL;
  if (flock(fd,LOCK_EX|LOCK_NB)) { close(fd); return NULL; }
  FILE *f=fdopen(fd,"a+"); if (!f) { close(fd); return NULL; }
  return rl_wrap(f);
#else
  return NULL;
#endif
}
MOONBIT_FFI_EXPORT int rl_rename(moonbit_bytes_t a, moonbit_bytes_t b, moonbit_bytes_t directory) {
#ifndef _WIN32
  if (rename((const char *)a,(const char *)b)) return -1;
  int fd=open((const char *)directory,O_RDONLY); if (fd<0) return -1;
  int r=fsync(fd); close(fd); return r;
#else
  return -1;
#endif
}
MOONBIT_FFI_EXPORT int64_t rl_size(moonbit_bytes_t path) {
#ifndef _WIN32
  struct stat s;
  if (lstat((const char *)path,&s) || !S_ISREG(s.st_mode)) return -1;
  return (int64_t)s.st_size;
#else
  return -1;
#endif
}
// SHA-256 per FIPS 180-4. This detects changed bytes, not the authenticity of a log.
typedef struct { uint32_t h[8]; uint64_t n; unsigned char buf[64]; size_t used; } rl_sha;
static const uint32_t rl_k[64]={
0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2};
#define RL_R(x,n) (((x)>>(n))|((x)<<(32-(n))))
static void rl_block(rl_sha *s,const unsigned char *p) {
  uint32_t w[64];
  for(int i=0;i<16;i++) w[i]=((uint32_t)p[4*i]<<24)|((uint32_t)p[4*i+1]<<16)|((uint32_t)p[4*i+2]<<8)|p[4*i+3];
  for(int i=16;i<64;i++) {uint32_t a=w[i-15],b=w[i-2]; w[i]=w[i-16]+(RL_R(a,7)^RL_R(a,18)^(a>>3))+w[i-7]+(RL_R(b,17)^RL_R(b,19)^(b>>10));}
  uint32_t a=s->h[0],b=s->h[1],c=s->h[2],d=s->h[3],e=s->h[4],f=s->h[5],g=s->h[6],h=s->h[7];
  for(int i=0;i<64;i++) {uint32_t t1=h+(RL_R(e,6)^RL_R(e,11)^RL_R(e,25))+((e&f)^(~e&g))+rl_k[i]+w[i]; uint32_t t2=(RL_R(a,2)^RL_R(a,13)^RL_R(a,22))+((a&b)^(a&c)^(b&c));h=g;g=f;f=e;e=d+t1;d=c;c=b;b=a;a=t1+t2;}
  s->h[0]+=a;s->h[1]+=b;s->h[2]+=c;s->h[3]+=d;s->h[4]+=e;s->h[5]+=f;s->h[6]+=g;s->h[7]+=h;
}
static void rl_sha_init(rl_sha *s) {
  uint32_t h[8]={0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};
  memcpy(s->h,h,sizeof(h));s->n=0;s->used=0;
}
static void rl_update(rl_sha *s,const unsigned char *p,size_t n) {
  s->n+=(uint64_t)n;
  while(n) {size_t take=64-s->used;if(take>n) take=n;memcpy(s->buf+s->used,p,take);s->used+=take;p+=take;n-=take;if(s->used==64) {rl_block(s,s->buf);s->used=0;}}
}
static moonbit_bytes_t rl_digest(rl_sha *s) {
  uint64_t bits=s->n*8;unsigned char pad[128]={0x80};size_t n=s->used<56?56-s->used:120-s->used;
  rl_update(s,pad,n);for(int i=0;i<8;i++) pad[i]=(unsigned char)(bits>>(56-8*i));rl_update(s,pad,8);
  const char *hex="0123456789abcdef";moonbit_bytes_t out=moonbit_make_bytes(64,0);
  for(int i=0;i<32;i++) {unsigned char b=(unsigned char)(s->h[i/4]>>(24-8*(i%4)));out[2*i]=hex[b>>4];out[2*i+1]=hex[b&15];}return out;
}
MOONBIT_FFI_EXPORT moonbit_bytes_t rl_hash_bytes(moonbit_bytes_t data) {rl_sha s;rl_sha_init(&s);rl_update(&s,data,(size_t)Moonbit_array_length(data));return rl_digest(&s);}
MOONBIT_FFI_EXPORT moonbit_bytes_t rl_hash_file(moonbit_bytes_t path) {
  rl_stream *r=rl_open(path,0);if(!r) return moonbit_make_bytes(0,0);
  rl_sha s;rl_sha_init(&s);unsigned char buf[65536];size_t n;
  while((n=fread(buf,1,sizeof(buf),r->file))) rl_update(&s,buf,n);
  int error=ferror(r->file);rl_close(r);return error ? moonbit_make_bytes(0,0) : rl_digest(&s);
}
