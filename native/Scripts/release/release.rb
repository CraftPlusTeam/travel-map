#!/usr/bin/env ruby
# Ruby standard library only. Credentials and signing assets stay outside Git.
require 'base64'
require 'digest'
require 'fileutils'
require 'json'
require 'net/http'
require 'open3'
require 'openssl'
require 'rexml/document'
require 'shellwords'
require 'time'
require 'timeout'
require 'tmpdir'
require 'uri'

class TravelMapRelease
  BUNDLE = 'com.craftplusteam.travelmap'.freeze
  TEAM = 'BTYVH3R392'.freeze
  ACTIONS = %w[preflight register-bundle archive export verify upload status].freeze

  def initialize(env = ENV)
    @env = env
    @native = File.expand_path(env.fetch('TRAVELMAP_NATIVE_DIR', File.expand_path('../..', __dir__)))
    @version = env.fetch('TRAVELMAP_VERSION', '1.0.0')
    @build = env.fetch('TRAVELMAP_BUILD', '1')
    raise 'invalid-version' unless @version.match?(/\A\d+\.\d+(?:\.\d+)?\z/)
    raise 'invalid-build' unless @build.match?(/\A[1-9]\d*\z/)
    @output = File.expand_path(env.fetch('TRAVELMAP_RELEASE_DIR', File.join(@native, '.build-output', 'release', "#{@version}-#{@build}")))
    @archive = File.join(@output, 'TravelMap.xcarchive')
    @ipa = File.join(@output, 'export', 'TravelMap.ipa')
    @secrets = %w[ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH].map { |key| env[key] }.compact.reject(&:empty?)
  end

  def redact(text)
    result = text.dup
    @secrets.sort_by { |value| -value.length }.each { |value| result.gsub!(value, '[ASC_REDACTED]') }
    result.gsub!(/AuthKey_[A-Za-z0-9]+\.p8/, '[ASC_PRIVATE_KEY_FILE]')
    result.gsub!(/eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/, '[TOKEN_REDACTED]')
    result.gsub!(/-----BEGIN[^\n]*PRIVATE KEY-----.*?-----END[^\n]*PRIVATE KEY-----/m, '[PRIVATE_KEY_REDACTED]')
    result
  end

  def token
    return @token if @token
    helper = @env['ASC_JWT_HELPER']
    if helper && !helper.empty?
      value, _, status = Open3.capture3('/usr/bin/ruby', File.expand_path(helper))
      raise 'jwt-helper-failed' unless status.success? && value.strip.split('.').size == 3
      @token = value.strip
    else
      key_path, key_id, issuer = credentials
      key = OpenSSL::PKey.read(File.binread(key_path))
      raise 'api-key-must-use-p256' unless key.is_a?(OpenSSL::PKey::EC) && key.group.curve_name == 'prime256v1'
      encode = lambda { |value| Base64.urlsafe_encode64(value).delete('=') }
      header = encode.call(JSON.generate(alg: 'ES256', kid: key_id, typ: 'JWT'))
      payload = encode.call(JSON.generate(iss: issuer, iat: Time.now.to_i, exp: Time.now.to_i + 900, aud: 'appstoreconnect-v1'))
      signing_input = "#{header}.#{payload}"
      der = key.dsa_sign_asn1(Digest::SHA256.digest(signing_input))
      raw = OpenSSL::ASN1.decode(der).value.map { |number| [number.value.to_s(16).rjust(64, '0')].pack('H*') }.join
      @token = "#{signing_input}.#{encode.call(raw)}"
    end
    @secrets << @token
    @token
  end

  def credentials
    values = %w[ASC_KEY_PATH ASC_KEY_ID ASC_ISSUER_ID].map do |name|
      value = @env.fetch(name) { raise "missing-#{name}" }
      raise "empty-#{name}" if value.empty?
      value
    end
    values[0] = File.expand_path(values[0])
    raise 'api-key-unreadable' unless File.file?(values[0]) && File.readable?(values[0])
    @secrets.concat(values)
    values
  end

  def api(method, path, body = nil)
    # Accept API-relative paths only; credentials never follow redirects.
    raise 'invalid-api-path' unless path.start_with?('/v1/') && !path.match?(/[\r\n]/)
    uri = URI('https://api.appstoreconnect.apple.com' + path)
    request = {'GET' => Net::HTTP::Get, 'POST' => Net::HTTP::Post}.fetch(method).new(uri)
    request['Authorization'] = 'Bearer ' + token
    if body
      request['Content-Type'] = 'application/json'
      request.body = JSON.generate(body)
    end
    http = Net::HTTP.new(uri.host, 443)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 30
    response = http.start { |client| client.request(request) }
    parsed = JSON.parse(response.body)
    unless response.is_a?(Net::HTTPSuccess)
      codes = parsed.fetch('errors', []).map { |error| error['code'] }.join(',')
      raise "asc-http-#{response.code}:#{codes}"
    end
    parsed
  end

  def records(resource, field, value, extra = {})
    query = URI.encode_www_form({'filter[' + field + ']' => value, 'limit' => 200}.merge(extra))
    api('GET', "/v1/#{resource}?#{query}").fetch('data')
  end

  def app!(required = true)
    apps = records('apps', 'bundleId', BUNDLE)
    raise 'duplicate-app-records' if apps.size > 1
    if apps.empty?
      raise 'app-record-missing-create-in-App-Store-Connect-web' if required
      return nil
    end
    app = apps.first
    attributes = app.fetch('attributes')
    raise 'app-metadata-mismatch' unless attributes['bundleId'] == BUNDLE && attributes['sku'] == BUNDLE && attributes['primaryLocale'] == 'ja'
    app
  end

  def prepare_output
    FileUtils.mkdir_p(@output, mode: 0700)
    File.chmod(0700, @output)
  end

  def run(label, arguments, seconds)
    prepare_output
    path = File.join(@output, "#{label}.log")
    puts "#{label}: started; redacted log: #{path}"
    result = nil
    File.open(path, 'w', 0600) do |log|
      log.sync = true
      log.puts "utc=#{Time.now.utc.iso8601} action=#{label} bundle=#{BUNDLE} version=#{@version} build=#{@build}"
      Open3.popen2e(*arguments, chdir: @native, pgroup: true) do |input, stream, wait|
        input.close
        begin
          private_block = false
          Timeout.timeout(seconds) do
            stream.each_line do |line|
              private_block = true if line.include?('-----BEGIN') && line.include?('PRIVATE KEY')
              if private_block
                private_block = false if line.include?('-----END') && line.include?('PRIVATE KEY')
                log.puts '[PRIVATE_KEY_REDACTED]'
              else
                log.write(redact(line))
              end
            end
            result = wait.value.exitstatus || 128
          end
        rescue Timeout::Error, Interrupt
          Process.kill('TERM', -wait.pid) rescue nil
          sleep 2
          Process.kill('KILL', -wait.pid) rescue nil if wait.alive?
          wait.join
          raise "#{label}-interrupted-or-timeout"
        end
        log.puts "exit=#{result}"
      end
    end
    raise "#{label}-failed-exit-#{result}-see-redacted-log" unless result == 0
    puts "#{label}: succeeded"
  end

  def auth_arguments
    key_path, key_id, issuer = credentials
    ['-allowProvisioningUpdates', '-authenticationKeyPath', key_path,
     '-authenticationKeyID', key_id, '-authenticationKeyIssuerID', issuer]
  end

  def plist(path)
    # plutil cannot convert provisioning-profile Date/Data values directly to JSON.
    value, _, status = Open3.capture3('/usr/bin/plutil', '-convert', 'xml1', '-o', '-', path)
    raise 'plist-read-failed' unless status.success?
    decode_plist(REXML::Document.new(value).root.elements[1])
  end

  def decode_plist(node)
    case node.name
    when 'dict'
      node.elements.to_a.each_slice(2).each_with_object({}) do |pair, result|
        key, value = pair
        raise 'plist-dictionary-invalid' unless key.name == 'key' && value
        result[key.text.to_s] = decode_plist(value)
      end
    when 'array' then node.elements.to_a.map { |value| decode_plist(value) }
    when 'true' then true
    when 'false' then false
    when 'integer' then Integer(node.text)
    when 'real' then Float(node.text)
    when 'data' then Base64.decode64(node.text.to_s)
    when 'string', 'date' then node.text.to_s
    else raise 'plist-value-type-unsupported'
    end
  end

  def validate_archive
    properties = plist(File.join(@archive, 'Info.plist')).fetch('ApplicationProperties')
    expected = {'CFBundleIdentifier' => BUNDLE, 'Team' => TEAM, 'CFBundleShortVersionString' => @version, 'CFBundleVersion' => @build}
    raise 'archive-metadata-mismatch' unless expected.all? { |key, value| properties[key] == value }
    app_path = File.expand_path(properties.fetch('ApplicationPath'), File.join(@archive, 'Products'))
    raise 'archive-app-path-invalid' unless app_path.start_with?(File.join(@archive, 'Products', 'Applications') + '/')
    raise 'archive-privacy-manifest-missing' unless File.file?(File.join(app_path, 'PrivacyInfo.xcprivacy'))
    _, _, status = Open3.capture3('/usr/bin/codesign', '--verify', '--deep', '--strict', app_path)
    raise 'archive-signature-invalid' unless status.success?
    properties
  end

  def verify_ipa
    raise 'ipa-missing' unless File.file?(@ipa)
    source_path = File.join(@output, 'source-sha.txt')
    source = File.file?(source_path) ? File.read(source_path).strip : @env.fetch('TRAVELMAP_SOURCE_SHA') { raise 'missing-TRAVELMAP_SOURCE_SHA' }
    raise 'invalid-source-sha' unless source.match?(/\A[0-9a-f]{40}\z/)
    profile_expiration = nil
    Dir.mktmpdir('verify-', @output) do |temporary|
      _, _, status = Open3.capture3('/usr/bin/ditto', '-x', '-k', @ipa, temporary)
      raise 'ipa-extract-failed' unless status.success?
      apps = Dir.glob(File.join(temporary, 'Payload', '*.app'))
      raise 'ipa-app-count-mismatch' unless apps.size == 1
      app = apps.first
      info = plist(File.join(app, 'Info.plist'))
      expected = {'CFBundleIdentifier' => BUNDLE, 'CFBundleShortVersionString' => @version, 'CFBundleVersion' => @build}
      raise 'ipa-metadata-mismatch' unless expected.all? { |key, value| info[key] == value }
      _, _, valid = Open3.capture3('/usr/bin/codesign', '--verify', '--deep', '--strict', app)
      _, details, read = Open3.capture3('/usr/bin/codesign', '-dv', '--verbose=4', app)
      raise 'ipa-signature-or-team-invalid' unless valid.success? && read.success? && details.lines.any? { |line| line.strip == "TeamIdentifier=#{TEAM}" }
      profile, _, decoded = Open3.capture3('/usr/bin/security', 'cms', '-D', '-i', File.join(app, 'embedded.mobileprovision'))
      raise 'ipa-provisioning-profile-invalid' unless decoded.success?
      xml_path = File.join(temporary, 'profile.plist')
      File.binwrite(xml_path, profile)
      provision = plist(xml_path)
      entitlements = provision.fetch('Entitlements')
      raise 'ipa-not-app-store-distribution' unless provision['TeamIdentifier'] == [TEAM] && entitlements['application-identifier'] == "#{TEAM}.#{BUNDLE}" && entitlements['get-task-allow'] == false && !provision.key?('ProvisionedDevices') && provision['ProvisionsAllDevices'] != true && Time.parse(provision.fetch('ExpirationDate')) > Time.now
      profile_expiration = provision.fetch('ExpirationDate')
    end
    data = {source: source, bundle: BUNDLE, team: TEAM, version: @version, build: @build, sha256: Digest::SHA256.file(@ipa).hexdigest, signatureVerified: true, appStoreProfileVerified: true, profileExpiration: profile_expiration}
    File.write(File.join(@output, 'verified-ipa.json'), JSON.pretty_generate(data) + "\n")
    puts JSON.generate(data)
    data
  end

  def execute(action)
    case action
    when 'preflight', 'register-bundle'
      bundles = records('bundleIds', 'identifier', BUNDLE)
      raise 'duplicate-bundle-records' if bundles.size > 1
      if bundles.empty? && action == 'register-bundle'
        bundles = [api('POST', '/v1/bundleIds', {data: {type: 'bundleIds', attributes: {identifier: BUNDLE, name: 'Travel Map', platform: 'IOS', seedId: TEAM}}}).fetch('data')]
      end
      bundles.each { |bundle| raise 'bundle-team-mismatch' unless bundle.dig('attributes', 'seedId') == TEAM }
      app = app!(false)
      puts JSON.generate(bundle: BUNDLE, team: TEAM, registeredBundle: !bundles.empty?, appId: app && app['id'], appName: app && app.dig('attributes', 'name'), appRecordRequired: app.nil?)
    when 'archive'
      source = @env.fetch('TRAVELMAP_SOURCE_SHA') { raise 'missing-TRAVELMAP_SOURCE_SHA' }
      raise 'invalid-source-sha' unless source.match?(/\A[0-9a-f]{40}\z/)
      raise 'archive-already-exists-use-a-new-build-or-output-directory' if File.exist?(@archive)
      raise 'generated-project-missing-run-xcodegen' unless File.directory?(File.join(@native, 'TravelMap.xcodeproj'))
      arguments = ['/usr/bin/xcodebuild', 'archive', '-project', 'TravelMap.xcodeproj', '-scheme', 'TravelMap', '-configuration', 'Release', '-destination', 'generic/platform=iOS', '-archivePath', @archive, '-derivedDataPath', File.join(@output, 'DerivedData'), '-jobs', '2', "DEVELOPMENT_TEAM=#{TEAM}", 'CODE_SIGN_STYLE=Automatic', 'CODE_SIGN_IDENTITY=Apple Development', "MARKETING_VERSION=#{@version}", "CURRENT_PROJECT_VERSION=#{@build}"]
      keychain = @env['TRAVELMAP_SIGNING_KEYCHAIN']
      arguments << 'OTHER_CODE_SIGN_FLAGS=--keychain ' + Shellwords.escape(File.expand_path(keychain)) if keychain && !keychain.empty?
      run('archive', arguments + auth_arguments, 1800)
      validate_archive
      File.write(File.join(@output, 'source-sha.txt'), source + "\n")
    when 'export'
      validate_archive
      raise 'ipa-already-exists-verify-existing-artifact' if File.exist?(@ipa)
      arguments = ['/usr/bin/xcodebuild', '-exportArchive', '-archivePath', @archive, '-exportPath', File.join(@output, 'export'), '-exportOptionsPlist', File.join(__dir__, 'ExportOptions.plist')]
      run('export', arguments + auth_arguments, 1200)
      verify_ipa
    when 'verify'
      prepare_output
      verify_ipa
    when 'upload'
      app = app!
      data = verify_ipa
      expected = @env.fetch('TRAVELMAP_EXPECTED_IPA_SHA256') { raise 'missing-TRAVELMAP_EXPECTED_IPA_SHA256-run-verify-first' }
      raise 'ipa-sha256-mismatch' unless expected == data[:sha256]
      marker = File.join(@output, 'uploaded-ipa.json')
      if File.file?(marker)
        raise 'upload-marker-mismatch' unless JSON.parse(File.read(marker))['sha256'] == expected
        puts 'This IPA was already uploaded successfully; use status to check Apple processing.'
        return
      end
      key_path, key_id, issuer = credentials
      run('upload', ['/usr/bin/xcrun', 'altool', '--upload-app', '-f', @ipa, '--api-key', key_id, '--api-issuer', issuer, '--p8-file-path', key_path, '--output-format', 'json'], 1200)
      File.write(marker, JSON.pretty_generate(data.merge(appId: app['id'], uploadedAt: Time.now.utc.iso8601)) + "\n")
      puts 'Upload accepted; run status until processingState is VALID and internalBuildState is ready.'
    when 'status'
      app = app!
      builds = records('builds', 'app', app['id'], {'sort' => '-uploadedDate', 'include' => 'preReleaseVersion'})
      matches = builds.select { |build| build.dig('attributes', 'version') == @build }
      matching = nil
      matches.each do |build|
        version_id = build.dig('relationships', 'preReleaseVersion', 'data', 'id')
        version = api('GET', "/v1/preReleaseVersions/#{version_id}").fetch('data')
        matching = build if version.dig('attributes', 'version') == @version && version.dig('attributes', 'platform') == 'IOS'
      end
      raise 'build-not-visible-yet' unless matching
      details = api('GET', "/v1/builds/#{matching['id']}/buildBetaDetail").fetch('data').fetch('attributes')
      attributes = matching.fetch('attributes')
      ready = attributes['processingState'] == 'VALID' && attributes['expired'] == false && %w[READY_FOR_BETA_TESTING IN_BETA_TESTING].include?(details['internalBuildState'])
      puts JSON.generate(appId: app['id'], buildId: matching['id'], version: @version, build: @build, processingState: attributes['processingState'], expired: attributes['expired'], usesNonExemptEncryption: attributes['usesNonExemptEncryption'], internalBuildState: details['internalBuildState'], externalBuildState: details['externalBuildState'], readyForInternalTesting: ready, url: "https://appstoreconnect.apple.com/apps/#{app['id']}/testflight/ios")
      raise 'apple-processing-or-compliance-pending' unless ready
    else
      raise 'unsupported-action'
    end
  end
end

if $PROGRAM_NAME == __FILE__
  File.umask(0077)
  action = ARGV.first
  if ['--help', '-h', nil].include?(action)
    puts "Usage: ruby Scripts/release/release.rb <#{TravelMapRelease::ACTIONS.join('|')}>"
    puts 'Read RELEASE.md for credential, signing, source SHA, and artifact SHA requirements.'
    exit 0
  end
  abort 'unsupported-action' unless TravelMapRelease::ACTIONS.include?(action)
  release = nil
  begin
    release = TravelMapRelease.new
    release.execute(action)
  rescue => error
    # Do not print arbitrary exception messages: key parsers and HTTP libraries may include credentials.
    safe = error.message.match?(/\A[a-zA-Z0-9,:_.-]+\z/) ? error.message : error.class.name
    warn(release ? release.redact("release-failed: #{safe}") : "release-failed: #{safe}")
    exit 2
  end
end
