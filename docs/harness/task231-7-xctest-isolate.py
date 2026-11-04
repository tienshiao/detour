"""Rewrite DetourTests XCTestCase subclasses for Swift 6 with main-actor default isolation.

XCTest declares XCTestCase's initializers and setUp/tearDown nonisolated; with default
isolation a test class infers main-actor isolation for them, which Swift 6 rejects. So:
the class is `nonisolated`; each member and nested type is `@MainActor`; sync
setUp/tearDown overrides stay nonisolated with their body in MainActor.assumeIsolated
(XCTest calls them on the main thread); extensions of those classes are @MainActor.
Relies on the files' formatting: types at column 0, members at 4 spaces.
"""
import re, sys, glob, os
root = sys.argv[1]
files = sorted(glob.glob(os.path.join(root, '*.swift')))
src = {f: open(f).read() for f in files}

# Test classes: direct XCTestCase subclasses, then subclasses of those, transitively.
decl = re.compile(r'^((?:final |open |public |private |fileprivate )*)class (\w+)\s*:\s*([\w.]+)', re.M)
bases = {'XCTestCase'}
changed = True
while changed:
    changed = False
    for s in src.values():
        for m in decl.finditer(s):
            if m.group(3) in bases and m.group(2) not in bases:
                bases.add(m.group(2)); changed = True
test_classes = bases - {'XCTestCase'}

member = re.compile(r'^    ((?:@\w+(?:\([^)]*\))? )*)((?:(?:private|fileprivate|internal|public|static|class|final|override|required|convenience|mutating|lazy|weak)\s+)*)(func|init|subscript|var|let|struct|enum|final class|class|actor|typealias)\b')
setup_names = ('setUp', 'tearDown', 'setUpWithError', 'tearDownWithError')
stats = {'classes': 0, 'members': 0, 'wrapped': 0, 'extensions': 0}

for f in files:
    lines = src[f].split('\n')
    out = []
    i = 0
    in_class = False
    while i < len(lines):
        l = lines[i]
        m = re.match(r'^((?:@\w+(?:\([^)]*\))? )*)((?:final |open |private |fileprivate )*)class (\w+)\s*:', l)
        if m and m.group(3) in test_classes and 'nonisolated' not in l:
            out.append(m.group(1) + 'nonisolated ' + l[len(m.group(1)):]); stats['classes'] += 1
            in_class = l.rstrip().endswith('{') and not l.rstrip().endswith('{}')
            i += 1; continue
        em = re.match(r'^((?:private |fileprivate )?)extension (\w+)\b', l)
        if em and em.group(2) in test_classes and '@MainActor' not in l:
            out.append('@MainActor ' + l); stats['extensions'] += 1; i += 1; continue
        if in_class and l == '}':
            in_class = False; out.append(l); i += 1; continue
        if in_class:
            mm = member.match(l)
            if mm and 'nonisolated' not in l and '@MainActor' not in (mm.group(1) or ''):
                kw = mm.group(3); mods = mm.group(2)
                sig = re.match(r'^    .*?\bfunc (\w+)\(\)\s*(async\s*)?(throws\s*)?\{\s*$', l)
                is_setup = 'override' in mods and sig and sig.group(1) in setup_names
                if kw in ('var', 'let') and not re.search(r'\{\s*$', l):
                    out.append(l); i += 1; continue          # stored property: leave
                if kw == 'typealias':
                    out.append(l); i += 1; continue
                if is_setup and not sig.group(2):
                    # sync setUp/tearDown: keep nonisolated, run the body on the main actor
                    j = i + 1
                    while lines[j] != '    }': j += 1
                    body = lines[i+1:j]
                    throws = bool(sig.group(3))
                    out.append(l)
                    out.append('        // XCTest calls this on the main thread; the test state is main-actor.')
                    out.append(('        try MainActor.assumeIsolated {' if throws else '        MainActor.assumeIsolated {'))
                    out.extend(('    ' + b) if b.strip() else b for b in body)
                    out.append('        }')
                    out.append('    }')
                    stats['wrapped'] += 1
                    i = j + 1; continue
                out.append('    @MainActor ' + l[4:]); stats['members'] += 1; i += 1; continue
        out.append(l); i += 1
    new = '\n'.join(out)
    if new != src[f]:
        open(f, 'w').write(new)
print(stats, 'test classes:', len(test_classes))
