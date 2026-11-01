#!/usr/bin/env python3
"""Generate native fixtures of OUR diagnostic helpers. Ownership metadata is mocked.
Run the generated Ninja build under the host build slot, then its diagnostic-test.
This does not replace the real Objective-C ring integration test catalyst-msglog.m.
"""
from pathlib import Path
import sys
root = Path(__file__).resolve().parents[1]
out = Path(sys.argv[1]).resolve(); out.mkdir(parents=True, exist_ok=True)
def function(text, signature):
    start = text.index(signature); body = text.index('{', start); depth = 1; end = body + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}'); end += 1
    return text[start:end]
os = (root/'runtime/objc-os.mm').read_text()
runtime = (root/'runtime/objc-runtime-new.mm').read_text()
prefix = r'''
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string>
#define NO false
#define YES true
struct header_info {};
struct cls {
    const header_info *header; const char *name;
    const char *nameForLogging() { return name; }
    bool isMetaClass() { return false; }
};
using Class = cls*; using SEL = const char*; using IMP = void(*)();
static const header_info *_headerForClass(Class c) { return c->header; }
static const char *sel_getName(SEL s) { return s; }
struct { void assertLocked() {} } runtimeLock;
struct catalyst_owned_image { const header_info *hi; uintptr_t start, end; const char *name; };
static catalyst_owned_image catalystOwned[2];
static size_t catalystOwnedCount;
static int catalystMsgLogFD;
static bool catalystMsgLogRing;
#define CATALYST_RING 256
static char catalystRing[CATALYST_RING][160];
static unsigned catalystRingNext;
static void (*catalystThreadRingNote)(const char *);
'''
parts=[function(os,'int secure_open(')]
for sig in ['static const catalyst_owned_image *\ncatalyst_owned_header(', 'static bool\ncatalyst_owned_address(', 'static bool\ncatalyst_log_first_send(', 'extern "C" __attribute__((visibility("default"))) void\ncatalyst_objc_dump_messages(']:
    parts.append(function(runtime,sig))
main=r'''
static int failures;
static void expect(bool ok, const char *label) { printf("%s %s\n",ok?"ok":"FAIL",label); failures += !ok; }
static void owned() {}
static void foreign() {}
static void put(const std::string &p, mode_t mode) {
    int f=open(p.c_str(),O_CREAT|O_EXCL|O_WRONLY,mode);
    if(f<0 || write(f,"sentinel",8)!=8 || close(f)!=0 || chmod(p.c_str(),mode)!=0) abort();
}
int main(int argc, char **argv) {
    std::string d=argv[1], good=d+"/good", target=d+"/target", sym=d+"/sym", hard=d+"/hard", loose=d+"/loose";
    int flags=O_WRONLY|O_CREAT|O_TRUNC|O_APPEND|O_CLOEXEC;
    int f=secure_open(good.c_str(),flags,geteuid()); struct stat st={};
    expect(f>=0 && !fstat(f,&st) && (st.st_mode&0777)==0600,"new file mode 0600"); if(f>=0)close(f);
    put(target,0600); if(symlink(target.c_str(),sym.c_str())!=0) abort();
    expect(secure_open(sym.c_str(),flags,geteuid())<0,"symlink refused");
    stat(target.c_str(),&st); expect(st.st_size==8,"symlink target not truncated");
    if(link(target.c_str(),hard.c_str())!=0) abort();
    expect(secure_open(hard.c_str(),flags,geteuid())<0,"hardlink refused");
    stat(target.c_str(),&st); expect(st.st_size==8,"hardlink target not truncated");
    put(loose,0644); expect(secure_open(loose.c_str(),flags,geteuid())<0,"0644 file refused");
    expect(secure_open(good.c_str(),flags,geteuid()+1)<0,"other owner refused");
    expect(secure_open(d.c_str(),flags,geteuid())<0,"directory refused");
    f=secure_open(good.c_str(),flags,geteuid()); expect(f>=0,"existing safe regular file accepted"); if(f>=0)close(f);
    catalystMsgLogFD=open((d+"/ring").c_str(),O_CREAT|O_EXCL|O_RDWR,0600); catalystMsgLogRing=true;
    header_info h, unknown; cls own{&h,"Owned"}, other{&unknown,"SECRET"};
    catalystOwnedCount=1; catalystOwned[0]={&h,(uintptr_t)owned,(uintptr_t)owned+1,"own.dylib"};
    expect(!catalyst_log_first_send(&own,&own,"foreign",foreign),"foreign IMP excluded from ring");
    expect(!catalyst_log_first_send(&other,&other,"dynamic",owned),"unknown implementing class excluded");
    for(int i=0;i<300;i++) { char s[32]; snprintf(s,sizeof(s),"send%03d",i); catalyst_log_first_send(&other,&own,s,owned); }
    catalyst_objc_dump_messages(); lseek(catalystMsgLogFD,0,SEEK_SET); char buf[65536];
    ssize_t n=read(catalystMsgLogFD,buf,sizeof(buf)-1); buf[n>0?n:0]=0;
    expect(strstr(buf,"send044") && !strstr(buf,"send043") && strstr(buf,"send299"),"ring keeps last 256 sends");
    const char *first=strstr(buf,"send044"), *last=strstr(buf,"send299");
    expect(first && last && first<last,"ring dumps oldest first");
    expect(!strstr(buf,"SECRET") && !strstr(buf,"foreign") && !strstr(buf,"dynamic"),"ring excludes non-owned names and IMPs");
    expect(strstr(buf,"- other Owned send044 own.dylib"),"non-owned receiver anonymized");
    close(catalystMsgLogFD); printf("HARNESS done: %d failed\n",failures); return failures!=0;
}
'''
(out/'diagnostic-test.cpp').write_text(prefix+'\n#pragma GCC diagnostic push\n#pragma GCC diagnostic ignored \"-Wunused-result\"\n'+'\n'.join(parts)+'\n#pragma GCC diagnostic pop\n'+main)
(out/'build.ninja').write_text(f'rule cxx\n  command = c++ -std=c++14 -O1 -Wall $in -o $out\nbuild {out}/diagnostic-test: cxx {out}/diagnostic-test.cpp\n')
print(out/'diagnostic-test')
