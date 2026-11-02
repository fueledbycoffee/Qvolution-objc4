#!/usr/bin/env python3
"""Exercise the actual pending-category container without booting a guest."""
from pathlib import Path
import os,subprocess,tempfile
R=Path(__file__).resolve().parents[1]
s=(R/'runtime/objc-runtime-new.mm').read_text()
code=s[s.index('class category_list : nocopy_t {'):s.index('\nclass UnattachedCategories :')]
prefix=r'''
#include <cassert>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <utility>
#include <cstdio>
struct nocopy_t {};
struct category_t { int tag; };
struct alignas(8) header_info { int tag; };
struct locstamped_category_t { category_t *cat; header_info *hi; };
static int fls(unsigned x) { return x ? 32-__builtin_clz(x) : 0; }
static void *reallocf(void *p, size_t n) { return realloc(p,n); }
'''
checks=r'''
int main() {
    category_t cats[5] = {}; header_info headers[5] = {};
    auto entry = [&](unsigned i) { return locstamped_category_t{&cats[i],&headers[i]}; };
    category_list single(entry(0));
    single.erase(&cats[4]); assert(single.count()==1);
    single.erase(&cats[0]); assert(single.count()==0);
    single.append(entry(1)); assert(single.count()==1 && single.array()[0].cat==&cats[1]);
    category_list pair(entry(0)); pair.append(entry(1));
    pair.erase(&cats[0]); assert(pair.count()==1);
    assert(pair.array()[0].cat==&cats[1] && pair.array()[0].hi==&headers[1]);
    pair.erase(&cats[1]); assert(pair.count()==0);
    pair.append(entry(2)); assert(pair.count()==1 && pair.array()[0].cat==&cats[2]);
    category_list many;
    for (unsigned i=0;i<4;++i) many.append(entry(i));
    many.erase(&cats[1]); assert(many.count()==3);
    assert(many.array()[0].cat==&cats[0] && many.array()[1].cat==&cats[2] && many.array()[2].cat==&cats[3]);
    many.erase(&cats[4]); assert(many.count()==3);
    many.erase(&cats[3]); assert(many.count()==2);
    category_list moved(std::move(many)); assert(many.count()==0 && moved.count()==2);
    moved.erase(&cats[2]); moved.erase(&cats[0]); assert(moved.count()==0);
    puts("PASS pending-category erase: singleton, first/middle/last, absent, empty reuse and move");
}
'''
with tempfile.TemporaryDirectory(prefix='qv-category-erase-') as d:
    p=Path(d);(p/'probe.cpp').write_text(prefix+code+checks)
    subprocess.run(['clang++','-std=c++14','-fsanitize=address,undefined',str(p/'probe.cpp'),'-o',str(p/'probe')],check=True)
    # Sandbox tracing prevents LeakSanitizer attachment; keep ASan/UBSan enabled.
    subprocess.run([str(p/'probe')],check=True,env={**os.environ,'ASAN_OPTIONS':'detect_leaks=0'})
