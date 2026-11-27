#!/usr/bin/env ruby
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Checks that no schema under spec/schemas changes content without a new version ($id).
#
# Each schema in the working tree is compared with the same file at a base commit from this
# repository's own history:
#   - on a branch (a pull request or the merge queue): where it left origin/main;
#   - on main itself (a push): the parent commit;
#   - or the commit given with --base REF.
# A schema whose $id is the same as at the base but whose parsed JSON differs fails. A new
# schema, a deleted one, a bumped $id, or a formatting-only change passes.
#
# The base comes from git rather than the published copy at the $id URL, so the check judges
# this repository's own change: a fork that never publishes is not failed by upstream editing
# a published version in place.
#
# Usage: check_schema_versions.rb [--base REF]

require "json"
require "open3"
require "pathname"

SCHEMAS_DIR = "spec/schemas"

SchemaVersionViolation = Struct.new(:path, :id, keyword_init: true)

class SchemaBaseError < StandardError; end

def schema_git(repo, *args)
  out, err, status = Open3.capture3("git", "-C", repo.to_s, *args)
  [out, err, status]
end

# The commit to compare against when no --base is given.
def default_schema_base(repo)
  _, _, has_main = schema_git(repo, "rev-parse", "--verify", "-q", "refs/remotes/origin/main")
  unless has_main.success?
    raise SchemaBaseError, "origin/main not found; fetch it (CI: checkout with fetch-depth: 0) " \
                           "or pass --base REF"
  end

  _, _, on_main = schema_git(repo, "merge-base", "--is-ancestor", "HEAD", "refs/remotes/origin/main")
  args = on_main.success? ? ["rev-parse", "HEAD^"] : ["merge-base", "HEAD", "refs/remotes/origin/main"]
  out, err, status = schema_git(repo, *args)
  raise SchemaBaseError, "could not find the base commit: #{err.strip}" unless status.success?

  out.strip
end

# Schemas in the working tree whose $id matches the base commit's but whose content does not.
def schema_version_violations(repo, base)
  repo = Pathname.new(repo)
  (repo / SCHEMAS_DIR).glob("*.json").sort.filter_map do |file|
    rel = file.relative_path_from(repo).to_s
    head = JSON.parse(file.read)
    old_text, _, status = schema_git(repo, "show", "#{base}:#{rel}")
    next unless status.success? # new since the base

    old = JSON.parse(old_text)
    next unless head["$id"] == old["$id"]
    next if head == old

    SchemaVersionViolation.new(path: rel, id: head["$id"])
  end
end

if __FILE__ == $PROGRAM_NAME
  root = Pathname.new(__dir__).parent.parent
  base_arg = ARGV.index("--base")&.then { |i| ARGV[i + 1] }

  begin
    base = base_arg || default_schema_base(root)
  rescue SchemaBaseError => e
    warn "check_schema_versions: #{e.message}"
    exit 1
  end

  violations = schema_version_violations(root, base)
  if violations.any?
    violations.each do |v|
      warn "Schema changed without a version bump: #{v.path} (still $id #{v.id} as at #{base})\n" \
           "  To fix: bump the schema version ($id) to a new version number."
    end
    exit 1
  end

  puts "All schema version checks passed (base #{base})."
end
