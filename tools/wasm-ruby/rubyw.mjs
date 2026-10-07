#!/usr/bin/env node
// ---------------------------------------------------------------------------
// rubyw -- a CRuby interpreter for machines that have no native ruby.
//
// Runs the official ruby.wasm build (CRuby 3.3 -> wasm32-wasi) on Node's WASI
// through the @ruby/wasm-wasi RubyVM reactor interface. Close enough to
// SketchUp's embedded Ruby to develop and unit-test any pure-Ruby code that
// does not touch the SketchUp API -- which, by design, is the whole of
// OpenWalls::Core.
//
//   node rubyw.mjs script.rb [args...]
//   node rubyw.mjs -e 'puts 1 + 1'
//
// Run tools/bootstrap once to fetch the interpreter itself.
//
// ruby.wasm quirks handled here, so nobody has to rediscover them:
//
//   1. `$stdout.sync = true` corrupts the VM -- later File.read and even
//      TOPLEVEL_BINDING access segfault. Never set it; flush explicitly.
//   2. `load` and `require` against the host filesystem segfault outright.
//   3. Calling eval() once per source file segfaults non-deterministically
//      (roughly half the time at a dozen files). So require_relative is
//      resolved *statically on the JS side*: the entry file and everything it
//      pulls in are inlined into a single source string, evaluated once. A
//      Ruby-side fallback still handles genuinely dynamic requires.
//   4. The GC is unstable under Node's WASI. A small initial heap with a low
//      malloc trigger survives far more often than the defaults; tools/test
//      retries a crashed shard on top of that.
// ---------------------------------------------------------------------------
import { WASI } from 'node:wasi';
import { RubyVM } from '@ruby/wasm-wasi/dist/vm';
import { readFileSync, existsSync, statSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { argv, exit, cwd, stderr, env } from 'node:process';
import path from 'node:path';

const HERE = path.dirname(new URL(import.meta.url).pathname);
const WASM = path.join(HERE, 'node_modules', '@ruby', '3.3-wasm-wasi', 'dist', 'ruby+stdlib.wasm');

// Stdlib that must be required before the first host-filesystem read.
// Project code may not require anything outside this list.
const PRELOAD = ['json', 'set', 'stringio', 'time'];

const REQUIRE_RELATIVE = /^(\s*)require_relative\s+(['"])([^'"]+)\2\s*(#.*)?$/;

function resolveRb(target) {
  for (const candidate of [target, `${target}.rb`]) {
    if (existsSync(candidate) && statSync(candidate).isFile()) return candidate;
  }
  return null;
}

// Inlines require_relative graphs into one source string, dependencies first.
function bundle(entryFile) {
  const seen = new Set();
  const out = [];

  function inline(file) {
    const abs = path.resolve(file);
    if (seen.has(abs)) return;
    seen.add(abs);

    const body = [];
    for (const line of readFileSync(abs, 'utf8').split('\n')) {
      const m = line.match(REQUIRE_RELATIVE);
      if (m) {
        const target = resolveRb(path.resolve(path.dirname(abs), m[3]));
        if (target) {
          inline(target);
          body.push(`${m[1]}# [rubyw] inlined ${m[3]}`);
          continue;
        }
      }
      body.push(line);
    }
    out.push(`# ===== rubyw: ${abs} =====`, ...body);
  }

  inline(entryFile);
  return out.join('\n');
}

if (!existsSync(WASM)) {
  stderr.write('The ruby.wasm interpreter is not installed.\nRun tools/bootstrap first.\n');
  exit(127);
}

const args = argv.slice(2);
if (args.length === 0) {
  stderr.write('usage: rubyw.mjs <script.rb> [args...] | -e <code>\n');
  exit(2);
}

let program;
let scriptName = '-e';
if (args[0] === '-e') {
  program = args[1];
  args.splice(0, 2);
} else {
  scriptName = path.resolve(cwd(), args[0]);
  args.splice(0, 1);
  program = bundle(scriptName);
}

const wasi = new WASI({
  version: 'preview1',
  returnOnExit: true,
  env: {
    RUBY_THREAD_VM_STACK_SIZE: env.RUBY_THREAD_VM_STACK_SIZE || '8388608',
    RUBY_THREAD_MACHINE_STACK_SIZE: env.RUBY_THREAD_MACHINE_STACK_SIZE || '8388608',
    RUBY_GC_HEAP_INIT_SLOTS: env.RUBY_GC_HEAP_INIT_SLOTS || '10000',
    RUBY_GC_MALLOC_LIMIT: env.RUBY_GC_MALLOC_LIMIT || '1048576',
  },
  preopens: { '/home/user': '/home/user', '/tmp': '/tmp' },
});

const module_ = await WebAssembly.compile(await readFile(WASM));
const { vm } = await RubyVM.instantiateModule({ module: module_, wasip1: wasi });

const prelude = `
${PRELOAD.map((lib) => `require ${JSON.stringify(lib)}`).join('\n')}

# Fallback for genuinely dynamic loads. The common case was already inlined.
module RubyW
  PRELOADED = ${JSON.stringify(PRELOAD)}.freeze
  LOADED = {}

  def self.load_file(file)
    file = File.expand_path(file)
    return false if LOADED[file]

    LOADED[file] = true
    eval(File.read(file), TOPLEVEL_BINDING, file)
    true
  end

  def self.resolve(name, from)
    cands = name.start_with?('/') ? [name] : [File.expand_path(name, from), File.expand_path(name, Dir.pwd)]
    cands.flat_map { |c| c.end_with?('.rb') ? [c] : [c + '.rb', c] }.find { |c| File.file?(c) }
  end
end

module Kernel
  def require_relative(name)
    file = RubyW.resolve(name, ${JSON.stringify(path.dirname(scriptName === '-e' ? cwd() : scriptName))})
    raise LoadError, "cannot load such file -- #{name}" unless file

    RubyW.load_file(file)
  end

  def require(name)
    return true if RubyW::PRELOADED.include?(name.to_s)

    file = RubyW.resolve(name.to_s, Dir.pwd)
    raise LoadError, "cannot load such file -- #{name} (rubyw preloads only #{RubyW::PRELOADED.join(', ')})" unless file

    RubyW.load_file(file)
  end
end

$0 = ${JSON.stringify(scriptName)}
ARGV.replace(${JSON.stringify(args)})
`;

let status = 0;
try {
  vm.eval(prelude);
  vm.eval(program);
} catch (err) {
  const msg = String(err?.message ?? err).replace(/\s+$/, '');
  stderr.write(msg + '\n');
  status = 1;
}
try {
  vm.eval('$stdout.flush; $stderr.flush');
} catch {
  /* VM already gone */
}
exit(status);
