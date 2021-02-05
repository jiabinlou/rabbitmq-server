load("//bazel_erlang:bazel_erlang_lib.bzl", "ErlangLibInfo", "path_join")

RabbitmqHomeInfo = provider(
    doc = "An assembled RABBITMQ_HOME dir",
    fields = {
        'sbin': 'Files making up the sbin dir',
        'escript': 'Files making up the escript dir',
        'plugins': 'Files making up the plugins dir',
        'erlang_version': 'Version of the Erlang compiler used',
    },
)

def _copy_script(ctx, script):
    dest = ctx.actions.declare_file(path_join(ctx.label.name, "sbin", script.basename))
    args = ctx.actions.args()
    args.add_all([script, dest])
    ctx.actions.run(
        inputs = [script],
        outputs = [dest],
        executable = "cp",
        arguments = [args],
    )
    return dest

def _link_escript(ctx, escript):
    e = escript.files_to_run.executable
    s = ctx.actions.declare_file(path_join(ctx.label.name, "escript", e.basename))
    ctx.actions.symlink(
        output = s,
        target_file = e,
    )
    return s

def _plugins_dir_links(ctx, plugin):
    lib_info = plugin[ErlangLibInfo]
    output = ctx.actions.declare_directory(
        path_join(
            ctx.label.name,
            "plugins",
            "{}-{}".format(lib_info.lib_name, lib_info.lib_version),
        )
    )

    link_commands = []
    for f in lib_info.include:
        link_commands.append("ln -s ${{PWD}}/{source} {target}".format(
            source = f.path,
            target = path_join(output.path, "include", f.basename)
        ))
    for f in lib_info.beam:
        link_commands.append("ln -s ${{PWD}}/{source} {target}".format(
            source = f.path,
            target = path_join(output.path, "ebin", f.basename)
        ))
    for f in lib_info.priv:
        p = f.short_path.replace(plugin.label.package + "/", "")
        target = path_join(output.path, p)
        link_commands.append("mkdir -p $(dirname {})".format(target))
        link_commands.append("ln -s ${{PWD}}/{source} {target}".format(
            source = f.path,
            target = target,
        ))

    ctx.actions.run_shell(
        inputs = lib_info.include + lib_info.beam + lib_info.priv,
        outputs = [output],
        command = """set -euo pipefail
        mkdir -p {lib_dir}
        mkdir -p {lib_dir}/include
        mkdir -p {lib_dir}/ebin
        mkdir -p {lib_dir}/priv
        {link_commands}
        """.format(lib_dir=output.path, link_commands=" \\\n    && ".join(link_commands)),
    )
    return output

def _unique_versions(plugins):
    erlang_versions = []
    for plugin in plugins:
        erlang_version = plugin[ErlangLibInfo].erlang_version
        if not erlang_version in erlang_versions:
            erlang_versions.append(erlang_version)
    return erlang_versions

def _impl(ctx):
    erlang_versions = _unique_versions(ctx.attr.plugins)
    if len(erlang_versions) > 1:
        fail("plugins do not have a unified erlang version", erlang_versions)

    scripts = [_copy_script(ctx, script) for script in ctx.files._scripts]

    escripts = [_link_escript(ctx, escript) for escript in ctx.attr.escripts]

    plugins = [_plugins_dir_links(ctx, plugin) for plugin in ctx.attr.plugins]

    return [
        RabbitmqHomeInfo(
            sbin = scripts,
            escript = escripts,
            plugins = plugins,
            erlang_version = erlang_versions[0],
        ),
        DefaultInfo(
            files = depset(scripts + escripts + plugins),
        ),
    ]

rabbitmq_home = rule(
    implementation = _impl,
    attrs = {
        "_scripts": attr.label_list(
            default = [
                "//deps/rabbit:scripts/rabbitmq-env",
                "//deps/rabbit:scripts/rabbitmq-defaults",
                "//deps/rabbit:scripts/rabbitmq-server",
                "//deps/rabbit:scripts/rabbitmqctl",
            ],
            allow_files = True,
        ),
        "_erlang_version": attr.label(default = "//bazel_erlang:erlang_version"),
        "escripts": attr.label_list(),
        # Maybe we should not have to declare the deps here that rabbit/rabbit_common declare
        "plugins": attr.label_list(),
    },
)