# frozen_string_literal: true
# SPDX-License-Identifier: AGPL-3.0-only

require 'fileutils'
require 'json'
require 'open3'
require 'pty'
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
  targets.each_with_index do |(source, destination, username), index|
    env["EMPEIRA_ADDON_CONFIG_TARGETS_#{index}_SOURCE"] = source
    env["EMPEIRA_ADDON_CONFIG_TARGETS_#{index}_DESTINATION"] = destination
    env["EMPEIRA_ADDON_CONFIG_TARGETS_#{index}_USERNAME"] = username if username
  end
  env
end

def cli(env, *arguments)
  File.write(env.fetch('SYNC_TEST_LOG'), '')
  Open3.capture3(env, RbConfig.ruby, BIN, *arguments, chdir: env.fetch('PATH'))
end

def interactive_cli(env, input)
  File.write(env.fetch('SYNC_TEST_LOG'), '')
  output = +''
  status = nil
  PTY.spawn(env, RbConfig.ruby, BIN, chdir: env.fetch('PATH')) do |reader, writer, pid|
    writer.write(input)
    begin
      loop { output << reader.readpartial(4096) }
    rescue EOFError, Errno::EIO
      # PTYs report EIO at EOF on some platforms.
    end
    Process.wait(pid)
    status = $?.exitstatus
  end
  [output, status]
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
    configured = env.merge(configuration([['user@server:/control/', './'], ['../hiera common/', 'server:/hiera/', 'operator']]))
    configured['EMPEIRA_ADDON_CONFIG_TARGETS_2_SOURCE'] = 'ignored'
    configured['EMPEIRA_ADDON_CONFIG_TARGETS_2_DESTINATION'] = 'ignored'
    stdout, stderr, status = cli(configured)
    assert(status.success?, stderr)
    assert(calls(env).size == 2)
    assert(calls(env).map { |args| args.last(2) } == [
      ['user@server:/control/', "#{root}/"], ["#{directory}/hiera common/", 'operator@server:/hiera/']
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
      ['data.txt', 'server:/data.txt', 'operator'], ['server:/remote-file', './received', 'operator']
    ]))
    _, stderr, status = cli(configured)
    assert(status.success?, stderr)
    assert(calls(env).map { |args| args.last(2) } == [
      ["#{directory}/hiera common/", "#{root}/out/"], [file, "#{directory}/absolute/../destination"],
      [file, 'operator@server:/data.txt'], ['operator@server:/remote-file', "#{root}/received"]
    ])
  end

  check('rsync arguments and dry-run are passed literally without a shell') do
    source = 'server:/data/$(touch injected); literal/'
    configured = env.merge(configuration([[source, './-destination with spaces', 'operator']]))
    [[], ['--dry-run']].each do |options|
      _, stderr, status = cli(configured, *options)
      assert(status.success?, stderr)
      assert(calls(env) == [['-a', '--exclude=.git/', *options, '--', "operator@#{source}", "#{root}/-destination with spaces"]])
      assert(!File.exist?(File.join(stub_dir, 'injected')))
    end
  end

  check('rsync failure preserves output and exit code and stops remaining targets') do
    configured = env.merge(configuration([['server:/first/', './', 'operator'], ['server:/second/', './', 'operator']]), 'SYNC_TEST_EXIT' => '23')
    stdout, stderr, status = cli(configured)
    assert(status.exitstatus == 23)
    assert(calls(env).size == 1 && !stdout.include?('Sync 2/2') && !stdout.include?('Sync completed.'))
    assert(stdout.include?('native rsync output') && stderr.include?('native rsync error'))
    assert(stderr.include?('Error: rsync failed for sync 1/2 (exit code 23).'))
  end

  check('SSH username is configured for either direction and inline usernames remain compatible') do
    configured = env.merge(configuration([
      ['server:/pull/', './', 'operator'],
      ['./', 'server:/push/', 'operator'],
      ['inline@server:/already/', './'],
      ['../hiera common/', './']
    ]))
    stdout, stderr, status = cli(configured)
    assert(status.success?, stderr)
    assert(!stdout.include?('SSH username for'))
    assert(calls(env).map { |args| args.last(2) } == [
      ['operator@server:/pull/', "#{root}/"],
      ["#{root}/", 'operator@server:/push/'],
      ['inline@server:/already/', "#{root}/"],
      ["#{directory}/hiera common/", "#{root}/"]
    ])
    invalid = env.merge(configuration([['server:/remote/', './', 'bad name']]))
    _, stderr, status = cli(invalid)
    assert(!status.success? && stderr.include?('Invalid SSH username') && calls(env).empty?)
    conflicting = env.merge(configuration([['inline@server:/remote/', './', 'other']]))
    _, stderr, status = cli(conflicting)
    assert(!status.success? && stderr.include?('SSH username conflicts') && calls(env).empty?)
  end

  check('missing SSH username prompts once per host and fails closed without a terminal') do
    configured = env.merge(configuration([
      ['server:/first/', './'],
      ['./', 'server:/second/']
    ]))
    _, stderr, status = cli(configured)
    assert(!status.success? && stderr.include?('SSH username for server is missing') && calls(env).empty?)

    output, status = interactive_cli(configured, "operator\n")
    assert(status == 0, "Unexpected prompt failure: #{output}")
    assert(output.scan('SSH username for server:').size == 1)
    assert(calls(env).map { |args| args.last(2) } == [
      ['operator@server:/first/', "#{root}/"],
      ["#{root}/", 'operator@server:/second/']
    ])
    output, status = interactive_cli(configured, "bad user\n")
    assert(status != 0 && output.include?('Invalid SSH username') && calls(env).empty?)
  end

  check('missing rsync has an actionable error') do
    File.unlink(stub)
    stdout, stderr, status = cli(env.merge(configuration([['server:/data/', './', 'operator']])))
    assert(status.exitstatus == 127 && calls(env).empty? && !stdout.include?('Sync completed.'))
    assert(stderr == "Error: rsync is not installed or not available in PATH.\nPlease install rsync and retry.\n")
  end
end
