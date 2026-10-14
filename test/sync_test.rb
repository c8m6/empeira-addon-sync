# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

require 'fileutils'
require 'json'
require 'open3'
require 'rbconfig'
require 'tmpdir'

BIN = File.expand_path('../bin/sync', __dir__)

def assert(condition, message = 'Assertion failed')
  raise message unless condition
end

def check(name)
  yield
  puts "PASS #{name}"
end

def configuration(targets)
  env = { 'EMPEIRA_ADDON_CONFIG_TARGETS_COUNT' => targets.size.to_s }
  targets.each_with_index do |(source, destination), index|
    env["EMPEIRA_ADDON_CONFIG_TARGETS_#{index}_SOURCE"] = source
    env["EMPEIRA_ADDON_CONFIG_TARGETS_#{index}_DESTINATION"] = destination
  end
  env
end

def cli(env, *arguments)
  File.write(env.fetch('SYNC_TEST_LOG'), '')
  Open3.capture3(env, RbConfig.ruby, BIN, *arguments, chdir: env.fetch('PATH'))
end

def calls(env)
  File.readlines(env.fetch('SYNC_TEST_LOG')).map { |line| JSON.parse(line) }
end

Dir.mktmpdir('empeira-sync-test') do |directory|
  root = File.join(directory, 'control')
  stub_dir = File.join(directory, 'bin')
  FileUtils.mkdir_p([root, stub_dir, File.join(directory, 'hiera common')])
  stub = File.join(stub_dir, 'rsync')
  File.write(stub, <<~RUBY)
    #!#{RbConfig.ruby}
    require 'json'
    File.open(ENV.fetch('SYNC_TEST_LOG'), 'a') { |file| file.puts JSON.generate(ARGV) }
    puts 'native rsync output'
    warn 'native rsync error' if ENV['SYNC_TEST_EXIT']
    exit ENV.fetch('SYNC_TEST_EXIT', '0').to_i
  RUBY
  File.chmod(0o755, stub)
  env = ENV.keys.grep(/^EMPEIRA_/).to_h { |key| [key, nil] }.merge(
    'PATH' => stub_dir, 'EMPEIRA_CONTROL_REPO' => root,
    'SYNC_TEST_LOG' => File.join(directory, 'calls.jsonl'), 'SYNC_TEST_EXIT' => nil
  )

  check('configured targets use COUNT and run in array order; CLI and configuration errors') do
    configured = env.merge(configuration([['user@server:/control/', './'], ['../hiera common/', 'server:/hiera/']]))
    configured['EMPEIRA_ADDON_CONFIG_TARGETS_2_SOURCE'] = 'ignored'
    configured['EMPEIRA_ADDON_CONFIG_TARGETS_2_DESTINATION'] = 'ignored'
    stdout, stderr, status = cli(configured)
    assert(status.success?, stderr)
    assert(calls(env).size == 2)
    assert(calls(env).map { |args| args.last(2) } == [
      ['user@server:/control/', "#{root}/"], ["#{directory}/hiera common/", 'server:/hiera/']
    ])
    assert(stdout == "Sync 1/2\nSource: user@server:/control/\nDestination: ./\nnative rsync output\n" \
                     "Sync 2/2\nSource: ../hiera common/\nDestination: server:/hiera/\nnative rsync output\nSync completed.\n")
    assert(File.executable?(BIN))
    stdout, stderr, status = cli(env, '--help')
    assert(status.success? && stdout.include?('--dry-run') && calls(env).empty?, stderr)
    %w[run push pull status list --delete --dry].each do |argument|
      _, stderr, status = cli(configured, argument)
      assert(!status.success? && stderr.include?('Unsupported argument') && calls(env).empty?)
    end
    [nil, '-1', 'invalid'].each do |count|
      _, stderr, status = cli(configured.merge('EMPEIRA_ADDON_CONFIG_TARGETS_COUNT' => count))
      assert(!status.success? && stderr.include?('Configure addons.sync.config.targets') && calls(env).empty?)
    end
    _, stderr, status = cli(configured.merge('EMPEIRA_ADDON_CONFIG_TARGETS_1_DESTINATION' => ''))
    assert(!status.success? && stderr.include?('targets[1].destination') && calls(env).empty?)
    _, stderr, status = cli(env.merge(configuration([])))
    assert(status.success? && calls(env).empty?, stderr)
  end

  check('relative paths use control root; directory contents and absolute file paths are preserved') do
    file = File.join(root, 'data.txt')
    File.write(file, 'synthetic data')
    configured = env.merge(configuration([
      ['../hiera common', './out/'], [file, "#{directory}/absolute/../destination"],
      ['data.txt', 'server:/data.txt'], ['server:/remote-file', './received']
    ]))
    _, stderr, status = cli(configured)
    assert(status.success?, stderr)
    assert(calls(env).map { |args| args.last(2) } == [
      ["#{directory}/hiera common/", "#{root}/out/"], [file, "#{directory}/absolute/../destination"],
      [file, 'server:/data.txt'], ['server:/remote-file', "#{root}/received"]
    ])
  end

  check('rsync arguments and dry-run are passed literally without a shell') do
    source = 'server:/data/$(touch injected); literal/'
    configured = env.merge(configuration([[source, './-destination with spaces']]))
    [[], ['--dry-run']].each do |options|
      _, stderr, status = cli(configured, *options)
      assert(status.success?, stderr)
      assert(calls(env) == [['-a', '--exclude=.git/', *options, '--', source, "#{root}/-destination with spaces"]])
      assert(!File.exist?(File.join(stub_dir, 'injected')))
    end
  end

  check('rsync failure preserves output and exit code and stops remaining targets') do
    configured = env.merge(configuration([['server:/first/', './'], ['server:/second/', './']]), 'SYNC_TEST_EXIT' => '23')
    stdout, stderr, status = cli(configured)
    assert(status.exitstatus == 23)
    assert(calls(env).size == 1 && !stdout.include?('Sync 2/2') && !stdout.include?('Sync completed.'))
    assert(stdout.include?('native rsync output') && stderr.include?('native rsync error'))
    assert(stderr.include?('Error: rsync failed for sync 1/2 (exit code 23).'))
  end

  check('missing rsync has an actionable error') do
    File.unlink(stub)
    stdout, stderr, status = cli(env.merge(configuration([['server:/data/', './']])))
    assert(status.exitstatus == 127 && calls(env).empty? && !stdout.include?('Sync completed.'))
    assert(stderr == "Error: rsync is not installed or not available in PATH.\nPlease install rsync and retry.\n")
  end
end
