# Copyright 2020 Google
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""
Rust Analyzer Bazel rules.

rust_analyzer will generate a rust-project.json file for the
given targets. This file can be consumed by rust-analyzer as an alternative
to Cargo.toml files.
"""

load("//rust/platform:triple_mappings.bzl", "system_to_dylib_ext", "triple_to_system")
load("//rust/private:common.bzl", "rust_common")
load("//rust/private:rustc.bzl", "BuildInfo")
load("//rust/private:utils.bzl", "find_toolchain")

# We support only these rule kinds.
_rust_rules = [
    "rust_library",
    "rust_binary",
]

RustAnalyzerInfo = provider(
    doc = "RustAnalyzerInfo holds rust crate metadata for targets",
    fields = {
        "build_info": "BuildInfo: build info for this crate if present",
        "cfgs": "List[String]: features or other compilation --cfg settings",
        "crate": "rust_common.crate_info",
        "deps": "List[RustAnalyzerInfo]: direct dependencies",
        "env": "Dict{String: String}: Environment variables, used for the `env!` macro",
        "proc_macro_dylib_path": "File: compiled shared library output of proc-macro rule",
        "transitive_deps": "List[RustAnalyzerInfo]: transitive closure of dependencies",
    },
)

def _rust_analyzer_aspect_impl(target, ctx):
    if rust_common.crate_info not in target:
        return []

    toolchain = find_toolchain(ctx)

    # Always add test & debug_assertions (like here: https://github.com/rust-analyzer/rust-analyzer/blob/505ff4070a3de962dbde66f08b6550cda2eb4eab/crates/project_model/src/lib.rs#L379-L381)
    cfgs = ["test", "debug_assertions"]
    if hasattr(ctx.rule.attr, "crate_features"):
        cfgs += ['feature="{}"'.format(f) for f in ctx.rule.attr.crate_features]
    if hasattr(ctx.rule.attr, "rustc_flags"):
        cfgs += [f[6:] for f in ctx.rule.attr.rustc_flags if f.startswith("--cfg ") or f.startswith("--cfg=")]

    # Save BuildInfo if we find any (for build script output)
    build_info = None
    for dep in ctx.rule.attr.deps:
        if BuildInfo in dep:
            build_info = dep[BuildInfo]

    dep_infos = [dep[RustAnalyzerInfo] for dep in ctx.rule.attr.deps if RustAnalyzerInfo in dep]
    if hasattr(ctx.rule.attr, "proc_macro_deps"):
        dep_infos += [dep[RustAnalyzerInfo] for dep in ctx.rule.attr.proc_macro_deps if RustAnalyzerInfo in dep]
    transitive_deps = depset(direct = dep_infos, order = "postorder", transitive = [dep.transitive_deps for dep in dep_infos])

    crate_info = target[rust_common.crate_info]
    return [RustAnalyzerInfo(
        crate = crate_info,
        cfgs = cfgs,
        env = getattr(ctx.rule.attr, "rustc_env", {}),
        deps = dep_infos,
        transitive_deps = transitive_deps,
        proc_macro_dylib_path = find_proc_macro_dylib_path(toolchain, target),
        build_info = build_info,
    )]

def find_proc_macro_dylib_path(toolchain, target):
    """Find the proc_macro_dylib_path of target. Returns None if target crate is not type proc-macro.

    Args:
        toolchain: The current rust toolchain.
        target: The current target.
    Returns:
        (path): The path to the proc macro dylib, or None if this crate is not a proc-macro.
    """
    if target[rust_common.crate_info].type != "proc-macro":
        return None

    dylib_ext = system_to_dylib_ext(triple_to_system(toolchain.target_triple))
    for action in target.actions:
        for output in action.outputs.to_list():
            if output.extension == dylib_ext[1:]:
                return output.path

    # Failed to find the dylib path inside a proc-macro crate.
    # TODO: Should this be an error?
    return None

rust_analyzer_aspect = aspect(
    attr_aspects = ["deps", "proc_macro_deps"],
    implementation = _rust_analyzer_aspect_impl,
    toolchains = [str(Label("//rust:toolchain"))],
    incompatible_use_toolchain_transition = True,
    doc = "Annotates rust rules with RustAnalyzerInfo later used to build a rust-project.json",
)

_exec_root_tmpl = "__EXEC_ROOT__/"

def _crate_id(crate_info):
    """Returns a unique stable identifier for a crate

    Returns:
        (string): This crate's unique stable id.
    """
    return "ID-" + crate_info.root.path

def create_crate(ctx, info, crate_mapping):
    """Creates a crate in the rust-project.json format

    Args:
        ctx (ctx): The rule context
        info (RustAnalyzerInfo): The crate RustAnalyzerInfo for the current crate
        crate_mapping (dict): A dict of {String:Int} that memoizes crates for deps.

    Returns:
        (dict) The crate rust-project.json representation
    """
    crate = dict()
    crate["display_name"] = info.crate.name
    crate["edition"] = info.crate.edition
    crate["env"] = {}

    # Switch on external/ to determine if crates are in the workspace or remote.
    # TODO: Some folks may want to override this for vendored dependencies.
    if info.crate.root.path.startswith("external/"):
        crate["is_workspace_member"] = False
        crate["root_module"] = _exec_root_tmpl + info.crate.root.path
        crate_root = _exec_root_tmpl + info.crate.root.dirname
    else:
        crate["is_workspace_member"] = True
        crate["root_module"] = info.crate.root.path
        crate_root = info.crate.root.dirname

    if info.build_info != None:
        crate["env"].update({"OUT_DIR": _exec_root_tmpl + info.build_info.out_dir.path})
        crate["source"] = {
            # We have to tell rust-analyzer about our out_dir since it's not under the crate root.
            "exclude_dirs": [],
            "include_dirs": [crate_root, _exec_root_tmpl + info.build_info.out_dir.path],
        }
    crate["env"].update(info.env)

    deps = [
        {"crate": crate_mapping[_crate_id(d.crate)], "name": d.crate.name}
        for d in info.deps
    ]
    crate["deps"] = deps
    crate["cfg"] = info.cfgs
    crate["target"] = find_toolchain(ctx).target_triple
    if info.proc_macro_dylib_path != None:
        crate["proc_macro_dylib_path"] = _exec_root_tmpl + info.proc_macro_dylib_path
    return crate

# This implementation is incomplete because in order to get rustc env vars we
# would need to actually execute the build graph and gather the output of
# cargo_build_script rules. This would require a genrule to actually construct
# the JSON, rather than being able to build it completly in starlark.
# TODO(djmarcin): Run the cargo_build_scripts to gather env vars correctly.
def _rust_analyzer_impl(ctx):
    rust_toolchain = find_toolchain(ctx)

    if not rust_toolchain.rustc_srcs:
        fail(
            "Current Rust toolchain doesn't contain rustc sources in `rustc_srcs` attribute.",
            "These are needed by rust analyzer.",
            "If you are using the default Rust toolchain, add `rust_repositories(include_rustc_srcs = True, ...).` to your WORKSPACE file.",
        )
    sysroot_src = rust_toolchain.rustc_srcs.label.package + "/library"
    if rust_toolchain.rustc_srcs.label.workspace_root:
        sysroot_src = _exec_root_tmpl + rust_toolchain.rustc_srcs.label.workspace_root + "/" + sysroot_src

    # Gather all crates and their dependencies into an array.
    # Dependencies are referenced by index, so leaves should come first.
    crates = []
    crate_mapping = dict()
    idx = 0
    for target in ctx.attr.targets:
        if RustAnalyzerInfo not in target:
            continue

        # Add this crate's transitive deps to the crate mapping and output.
        for dep_info in target[RustAnalyzerInfo].transitive_deps.to_list():
            crate_id = _crate_id(dep_info.crate)
            if crate_id not in crate_mapping:
                crate_mapping[crate_id] = idx
                idx += 1
                crates.append(create_crate(ctx, dep_info, crate_mapping))

        # Add this crate to the crate mapping and output.
        crate_id = _crate_id(target[RustAnalyzerInfo].crate)
        if crate_id not in crate_mapping:
            crate_mapping[crate_id] = idx
            idx += 1
            crates.append(create_crate(ctx, target[RustAnalyzerInfo], crate_mapping))

    # TODO(djmarcin): Use json module once bazel 4.0 is released.
    ctx.actions.write(output = ctx.outputs.filename, content = struct(
        sysroot_src = sysroot_src,
        crates = crates,
    ).to_json())

rust_analyzer = rule(
    attrs = {
        "targets": attr.label_list(
            aspects = [rust_analyzer_aspect],
            doc = "List of all targets to be included in the index",
        ),
    },
    outputs = {
        "filename": "rust-project.json",
    },
    implementation = _rust_analyzer_impl,
    toolchains = [str(Label("//rust:toolchain"))],
    incompatible_use_toolchain_transition = True,
    doc = """\
Produces a rust-project.json for the given targets. Configure rust-analyzer to load the generated file via the linked projects mechanism.
""",
)
