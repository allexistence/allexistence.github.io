# Folder Structure

Quick reference for where things live in this repo. The site is Jekyll + the
[Chirpy](https://github.com/cotes2020/jekyll-theme-chirpy) theme (installed as a gem, not
vendored — its source isn't in this repo).

```
.
├── _posts/                  # blog posts, one folder per date
│   └── YYYY-MM-DD/
│       └── YYYY-MM-DD-slug.md
├── _tabs/                   # nav pages (Home is built-in, not a tab)
│   ├── about.md
│   ├── categories.md
│   └── tags.md
├── _data/
│   ├── contact.yml          # sidebar social icons (GitHub, LinkedIn, RSS)
│   └── share.yml            # post-sharing platform links
├── _includes/                # theme overrides — only files that differ from
│   └── footer.html           # the gem's defaults live here. footer.html adds the
│                              # floating Buy Me a Coffee widget sitewide.
├── _layouts/                  # same idea: theme layout overrides
│   └── home.html              # replaces the numbered pager with a single
│                               # "See more posts" button
├── _plugins/
│   └── posts-lastmod-hook.rb  # theme plugin, untouched
├── assets/
│   ├── img/avatar.jpg
│   └── lib/                 # theme's static assets (fonts, JS libs) — a git
│                             # submodule per .gitmodules, but NOT required:
│                             # self-hosting is disabled in _config.yml, so the
│                             # site loads these from a CDN instead. Safe to
│                             # leave uninitialized.
├── _config.yml               # main site config — theme options, nav, comments,
│                              # social links, pagination, etc.
├── Dockerfile                 # local preview image (Ruby + bundler + gems baked in)
├── docker-compose.yml          # `docker compose up` → http://localhost:4000
├── .dockerignore
├── Gemfile                    # Ruby gem dependencies (jekyll-theme-chirpy, etc.)
├── README.md                  # local dev instructions + how to add a post
└── STRUCTURE.md                # this file
```

## What's config vs. content

- **Config** (`_config.yml`, `_data/`) — site-wide settings: title, social links, comments
  provider (giscus), pagination, nav order.
- **Content** (`_posts/`, `_tabs/`) — the actual pages. Adding a post is just adding a file to
  `_posts/` (see [README.md](README.md) for the exact format).
- **Theme overrides** (`_includes/`, `_layouts/`) — only touch these if you're changing something
  the theme doesn't expose via `_config.yml`. Everything else about the theme's look/behavior
  comes from the `jekyll-theme-chirpy` gem and isn't in this repo at all.

## Categories & tags

These are **not** configured anywhere — they're derived automatically from the `categories:` and
`tags:` front matter across all posts. A category/tag only appears on `/categories/` or `/tags/`
once at least one published post uses it.

## Not committed (gitignored)

`.bundle`, `vendor`, `Gemfile.lock`, `.jekyll-cache`, `_site`, `.claude` (this harness's local
session state) — all local build artifacts / caches, regenerated automatically.
