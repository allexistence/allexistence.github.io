#!/usr/bin/env ruby
# frozen_string_literal: true
#
# Validates every post in _posts/ against this repo's conventions:
#   - filename matches YYYY-MM-DD-slug.md
#   - lives in a _posts/YYYY-MM-DD/ folder matching that same date
#   - has valid YAML front matter with title, date, categories, tags
#   - categories/tags are non-empty arrays
#
# Usage: ruby tools/check_post_format.rb

require "yaml"
require "date"

POSTS_DIR = File.join(__dir__, "..", "_posts")
FILENAME_RE = /\A(\d{4}-\d{2}-\d{2})-.+\.md\z/

errors = []
checked = 0

Dir.glob(File.join(POSTS_DIR, "**", "*.md")).sort.each do |path|
  checked += 1
  rel = path.sub("#{POSTS_DIR}/", "")
  filename = File.basename(path)
  folder = File.basename(File.dirname(path))

  # filename convention
  match = FILENAME_RE.match(filename)
  unless match
    errors << "#{rel}: filename must match YYYY-MM-DD-slug.md"
    next
  end

  file_date = match[1]

  # folder convention
  if folder != file_date
    errors << "#{rel}: lives in folder '#{folder}/' but filename date is '#{file_date}' — should be _posts/#{file_date}/#{filename}"
  end

  content = File.read(path)

  unless content.start_with?("---\n") || content.start_with?("---\r\n")
    errors << "#{rel}: missing front matter (must start with '---')"
    next
  end

  parts = content.split(/^---\s*$/, 3)
  if parts.length < 3
    errors << "#{rel}: front matter block is not closed with a second '---'"
    next
  end

  front_matter = begin
    YAML.safe_load(parts[1], permitted_classes: [Date, Time])
  rescue Psych::SyntaxError => e
    errors << "#{rel}: invalid YAML in front matter — #{e.message}"
    next
  end

  unless front_matter.is_a?(Hash)
    errors << "#{rel}: front matter did not parse to a set of key/value pairs"
    next
  end

  # required fields
  title = front_matter["title"]
  if title.nil? || !title.is_a?(String) || title.strip.empty?
    errors << "#{rel}: missing or empty 'title'"
  end

  date = front_matter["date"]
  if date.nil?
    errors << "#{rel}: missing 'date'"
  end

  categories = front_matter["categories"]
  if categories.nil? || !categories.is_a?(Array) || categories.empty?
    errors << "#{rel}: 'categories' must be a non-empty list, e.g. [Category Name]"
  end

  tags = front_matter["tags"]
  if tags.nil? || !tags.is_a?(Array) || tags.empty?
    errors << "#{rel}: 'tags' must be a non-empty list, e.g. [tag-one, tag-two]"
  end
end

if checked.zero?
  puts "No posts found under #{POSTS_DIR} — nothing to check."
  exit 0
end

if errors.empty?
  puts "All #{checked} post(s) passed format checks."
  exit 0
else
  puts "#{errors.size} problem(s) found across #{checked} post(s):"
  errors.each { |e| puts "  ✗ #{e}" }
  exit 1
end
