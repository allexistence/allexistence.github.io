# allexistence.github.io

Personal blog covering platform engineering, Kubernetes, and AI/ML infrastructure.

Built with [Jekyll](https://jekyllrb.com) + [Chirpy](https://github.com/cotes2020/jekyll-theme-chirpy), hosted on GitHub Pages.

🌐 [allexistence.github.io](https://allexistence.github.io)

## 1. Local development

Requires [Docker](https://www.docker.com/) — no local Ruby/Jekyll install needed.

```bash
docker compose up
```

Open [http://localhost:4000](http://localhost:4000). Edit any file and refresh the page — Jekyll
auto-rebuilds on save. If you edit `_config.yml`, restart instead of just refreshing:

```bash
docker compose restart
```

Stop the server with `Ctrl+C`, or `docker compose down` if it's running in the background. If you
add a gem to the `Gemfile`, rebuild the image:

```bash
docker compose up --build
```

## 2. How to add a post

Create a new file in [`_posts/`](_posts/), inside a folder named after the post's date, e.g.:

```
_posts/YYYY-MM-DD/YYYY-MM-DD-a-short-slug.md
```

The date must appear in both the folder name (for organization) and the filename itself — Jekyll
only recognizes a post by its filename, not its folder, so the date prefix on the file is required
either way.

Add front matter at the top of the file:

```yaml
---
title: "Post Title"
date: 2026-08-15 09:00:00 +0800
categories: [Category Name]
tags: [tag-one, tag-two, tag-three]
---
```

Then write the post in Markdown below the front matter. A few notes:

- **Categories** are broad sections (shown on the `/categories/` page) — keep each post to one or
  two.
- **Tags** are finer-grained keywords (shown on the `/tags/` page) — reuse existing tags where they
  fit so the tag cloud stays useful; check `/tags/` for what already exists.
- The homepage shows the 4 most recent posts with a "See more posts" button — no extra config
  needed, new posts just appear at the top automatically, newest first.
- Comments and emoji reactions are enabled by default on every post (via giscus) — nothing to turn
  on per post.
- To link out to an externally-hosted post instead of writing one here, see any of the existing
  Medium-redirect posts in `_posts/` for the pattern (a `<script>` redirect plus a fallback link).
