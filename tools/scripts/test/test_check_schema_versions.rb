# Copyright (c) Velaura AI.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "tmpdir"

require_relative "../check_schema_versions"

# Each test builds a throwaway git repository with a spec/schemas directory, commits a
# baseline, then edits the working tree and checks it against that baseline.
class TestCheckSchemaVersions < Minitest::Test
  def setup
    @repo = Pathname.new(Dir.mktmpdir("check_schema_versions_test"))
    git("init", "-q", "-b", "main")
    git("config", "user.email", "test@example.com")
    git("config", "user.name", "test")
    write_schema("a_schema.json", "v0.1", { "type" => "string" })
    write_schema("b_schema.json", "v0.1", { "type" => "integer" })
    commit("baseline")
  end

  def teardown
    FileUtils.remove_entry(@repo)
  end

  def git(*args)
    out, err, status = Open3.capture3("git", "-C", @repo.to_s, *args)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?

    out.strip
  end

  def write_schema(name, id, body, pretty: true)
    data = { "$schema" => "http://json-schema.org/draft-07/schema#", "$id" => id }.merge(body)
    path = @repo / "spec" / "schemas" / name
    FileUtils.mkdir_p(path.dirname)
    File.write(path, pretty ? "#{JSON.pretty_generate(data)}\n" : JSON.generate(data))
  end

  def commit(msg)
    git("add", "-A")
    git("commit", "-q", "-m", msg)
    git("rev-parse", "HEAD")
  end

  def violations(base = "HEAD")
    schema_version_violations(@repo, base)
  end

  def test_unchanged_schemas_pass
    assert_empty violations
  end

  def test_changed_content_with_the_same_id_fails
    write_schema("a_schema.json", "v0.1", { "type" => "number" })

    v = violations
    assert_equal ["spec/schemas/a_schema.json"], v.map(&:path)
    assert_equal "v0.1", v.first.id
  end

  def test_changed_content_with_a_bumped_id_passes
    write_schema("a_schema.json", "v0.2", { "type" => "number" })

    assert_empty violations
  end

  def test_a_new_schema_passes
    write_schema("c_schema.json", "v0.1", { "type" => "boolean" })

    assert_empty violations
  end

  def test_a_deleted_schema_passes
    FileUtils.rm(@repo / "spec" / "schemas" / "b_schema.json")

    assert_empty violations
  end

  # Only the parsed JSON counts: reformatting a schema must not force a version bump.
  def test_a_formatting_only_change_passes
    write_schema("a_schema.json", "v0.1", { "type" => "string" }, pretty: false)

    assert_empty violations
  end

  # On main itself (a push), the change under test is the last commit.
  def test_default_base_on_main_is_the_parent_commit
    baseline = git("rev-parse", "HEAD")
    write_schema("a_schema.json", "v0.2", { "type" => "number" })
    tip = commit("bump a")
    git("update-ref", "refs/remotes/origin/main", tip)

    assert_equal baseline, default_schema_base(@repo)
  end

  # On a branch (a pull request or the merge queue), the base is where it left main.
  def test_default_base_on_a_branch_is_the_merge_base_with_main
    fork_point = git("rev-parse", "HEAD")
    git("update-ref", "refs/remotes/origin/main", fork_point)
    git("switch", "-q", "-c", "topic")
    write_schema("a_schema.json", "v0.1", { "type" => "number" })
    commit("edit a in place")
    git("switch", "-q", "main")
    write_schema("b_schema.json", "v0.2", { "type" => "number" })
    git("update-ref", "refs/remotes/origin/main", commit("main moves on"))
    git("switch", "-q", "topic")

    assert_equal fork_point, default_schema_base(@repo)
    assert_equal ["spec/schemas/a_schema.json"], violations(default_schema_base(@repo)).map(&:path)
  end

  def test_default_base_without_origin_main_is_an_error
    assert_raises(SchemaBaseError) { default_schema_base(@repo) }
  end
end
