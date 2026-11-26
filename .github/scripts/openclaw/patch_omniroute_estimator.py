#!/usr/bin/env python3
# 2026-11-26: OmniRoute token-estimator hot patch, vendored from patch_work/patch-chunks.py.
"""Patch OmniRoute token-estimator chunks (usageEstimation.ts) in-place.

Usage: patch-chunks.py <infile> <outfile>
Fails loudly (exit 1) if the expected minified shape is absent, so an
upstream refactor can never be silently corrupted.
"""
import sys

STATE = 'var __est={c:new WeakMap(),m:0,h:0,s:0};'
LOG = ('if((__est.m+__est.h)%500===0)console.log("[PATCH-EST] calls="'
       '+(__est.m+__est.h)+" hit="+__est.h+" miss="+__est.m+" sampled="+__est.s);')
SAMPLE = ('if(a.length>16384){let _n=32,_b=a.length/_n,_s="";'
          'for(let _i=0;_i<_n;_i++){_s+=a.substr(Math.floor(_i*_b),512)}'
          '__est.s++;return Math.ceil(d(_s)*a.length/_s.length)}')

D_PRE = 'function d(a){if(!a||"string"!=typeof a)return 0;'
E_PRE = 'function e(a){if(!a||"object"!=typeof a)return 0;'
F_MARK = 'function f(a){'


def balance(text):
    depth = 0
    quote = None
    i = 0
    while i < len(text):
        ch = text[i]
        if quote:
            if ch == chr(92):
                i += 2
                continue
            if ch == quote:
                quote = None
        elif ch in (chr(34), chr(39), chr(96)):
            quote = ch
        elif ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
        i += 1
    return depth


def patch(src, dst):
    s = open(src, encoding='utf-8').read()
    if STATE in s:
        print('  already patched - skipping')
        return False
    marker = '659880:(a,b,c)=>{'
    i = s.find(marker)
    if i < 0:
        raise SystemExit('  module 659880 not found: upstream layout changed, aborting')
    j = s.find(D_PRE, i)
    k = s.find(E_PRE, j)
    m = s.find(F_MARK, k)
    if min(j, k, m) < 0:
        raise SystemExit('  estimator function shape not found, aborting')
    d_orig, e_orig = s[j:k], s[k:m]
    if balance(d_orig) or balance(e_orig):
        raise SystemExit('  unbalanced source slice, aborting')

    new_d = D_PRE + SAMPLE + d_orig[len(D_PRE):]
    e_tail = e_orig[len(E_PRE):]
    if not e_tail.endswith('}'):
        raise SystemExit('  unexpected e() tail, aborting')
    body = e_tail[:-1]
    body = body.replace('try{',
                        'try{let _h=__est.c.get(a);if(_h!==undefined){__est.h++;' + LOG + 'return _h}', 1)
    if body.count('return c+b') != 1:
        raise SystemExit('  estimator return shape not found, aborting')
    body = body.replace('return c+b',
                        'let _r=c+b;__est.m++;' + LOG + '__est.c.set(a,_r);return _r', 1)
    new_e = E_PRE + body + '}'
    if balance(new_e):
        raise SystemExit('  patched e() unbalanced, aborting')

    out = s[:i + len(marker)] + STATE + s[i + len(marker):j] + new_d + new_e + s[m:]
    if balance(out) != balance(s):
        raise SystemExit('  file brace balance changed, aborting')
    open(dst, 'w', encoding='utf-8').write(out)
    print('  patched %s -> %s (d %+d, e %+d bytes)' % (src, dst, len(new_d) - len(d_orig), len(new_e) - len(e_orig)))
    return True


if len(sys.argv) != 3:
    raise SystemExit(__doc__)
patch(sys.argv[1], sys.argv[2])
