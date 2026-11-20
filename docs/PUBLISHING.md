# Publishing a profile

A published profile is a public git repository, found by its name, so nothing is hosted. A
shelf of setup scripts isn't something you can share safely, because you can't combine two
of them. A shelf of profiles can be: each declares what it needs, the merged plan shows
everything before launch, and a conflict is a refusal. So the vendor of a tool or a
connector can publish the profile for it.

The quickest start is the
[template repository](https://github.com/antialias/sprite-profile-template): press "Use this
template", rename the profile, and push. Its workflow checks on every push that the profile
resolves.

## Names

| you publish | people pick |
|---|---|
| a repository `owner/sprite-profile-NAME`, with `profile.toml` at its root | `@owner/NAME` |
| a folder `NAME/` or `profiles/NAME/` in your collection, `owner/sprite-profiles` | `@owner/NAME` |
| a line `NAME = "REPO/path"` in your collection's `links.toml`, pointing into another of your repositories, such as a monorepo | `@owner/NAME` |

## Versions and the topic

Versions are tags: `v1.0.0` for a profile at a repository's root, `<folder>/v1.0.0` for one
in a folder (`profiles/linear/v1.0.0`). Give the repository the topic `sprite-profile` so
`sprite-profiles search` finds it:

```sh
git tag -a v1.0.0 -m "linear 1.0.0" && git push origin v1.0.0
gh repo edit --add-topic sprite-profile
```

Then [add it to the gallery](../../../issues/new?template=add-profile.yml) in the README.

## Check it before you tag

`sprite-profiles show @owner/NAME@main` resolves a pushed branch as a launch would and prints
what the profile can touch. A path pick must be a folder named for the profile, so a
checkout named `sprite-profile-NAME` is refused with `name_mismatch`; check it through a link
with the profile's name:

```sh
ln -sfn "$PWD" /tmp/NAME && sprite-profiles show /tmp/NAME && sprite-profiles plan claude-code /tmp/NAME
```

## Labels and connectors follow the publisher

A profile's label and connector name follow its publisher: `@acme/linear` is
`profile:acme.linear`, and only a repository owned by `acme` can give it.

[sprite-profile-shop-inventory](https://github.com/antialias/sprite-profile-shop-inventory)
is a complete example, published by the service it connects to.
[sprite-profile-apiary](https://github.com/antialias/sprite-profile-apiary) is another: it
routes Claude Code through [Apiary](https://apiary.wtf)'s switch proxy, an HTTPS proxy a
connector can't front, so its `setup.sh` enrols the Sprite as a device you approve, and
`checkpoint = false` keeps the device's token out of every checkpoint.

## Other git hosts

The same layout works on any git server. On a self-hosted Gitea,
`@git.example.com/team/linear` finds `team/sprite-profile-linear` there; a first part
holding a `.` is a host. It is fetched with `git`, through the credentials your git already
has, so a private repository works and sprite-profiles never asks for a password. Search
covers GitHub only.
