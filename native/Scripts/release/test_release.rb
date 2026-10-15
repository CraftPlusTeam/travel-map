require 'minitest/autorun'
require_relative 'release'

class ReleaseContractTest < Minitest::Test
  class AppFixture < TravelMapRelease
    attr_accessor :apps
    def records(*)
      apps
    end
  end

  def test_credentials_and_tokens_are_redacted
    release = TravelMapRelease.new('ASC_KEY_ID' => 'PRIVATE_KEY_ID', 'ASC_ISSUER_ID' => 'PRIVATE_ISSUER', 'ASC_KEY_PATH' => '/private/AuthKey_HIDDEN.p8')
    text = "PRIVATE_KEY_ID PRIVATE_ISSUER /private/AuthKey_HIDDEN.p8 eyJhbGciOiJFUzI1NiJ9.payload.signature\n-----BEGIN PRIVATE KEY-----\nsecret\n-----END PRIVATE KEY-----"
    result = release.redact(text)
    %w[PRIVATE_KEY_ID PRIVATE_ISSUER HIDDEN.p8 payload.signature secret].each { |value| refute_includes result, value }
    assert_includes result, '[PRIVATE_KEY_REDACTED]'
  end

  def test_wrong_app_sku_or_locale_blocks_upload_preflight
    release = AppFixture.new({})
    attributes = {'bundleId' => TravelMapRelease::BUNDLE, 'sku' => TravelMapRelease::BUNDLE, 'primaryLocale' => 'ja'}
    release.apps = [{'id' => '123', 'attributes' => attributes}]
    assert_equal '123', release.app!['id']
    %w[bundleId sku primaryLocale].each do |field|
      release.apps = [{'id' => '123', 'attributes' => attributes.merge(field => 'unexpected')}]
      assert_raises(RuntimeError) { release.app! }
    end
  end

  def test_missing_or_duplicate_app_records_block_upload
    release = AppFixture.new({})
    release.apps = []
    assert_nil release.app!(false)
    assert_raises(RuntimeError) { release.app! }
    release.apps = [{}, {}]
    assert_raises(RuntimeError) { release.app! }
  end

  def test_build_number_cannot_inject_extra_xcode_arguments
    ['', '0', '-1', '1 CODE_SIGNING_ALLOWED=NO', "1\n2"].each do |value|
      assert_raises(RuntimeError) { TravelMapRelease.new('TRAVELMAP_BUILD' => value) }
    end
  end

  def test_api_rejects_absolute_urls_before_authentication
    release = TravelMapRelease.new({})
    ['https://example.test/v1/apps', '//example.test/v1/apps', "/v1/apps\nAuthorization: test"].each do |path|
      error = assert_raises(RuntimeError) { release.api('GET', path) }
      assert_equal 'invalid-api-path', error.message
    end
  end

  def test_provisioning_profile_dates_data_and_booleans_are_preserved
    release = TravelMapRelease.new({})
    xml = '<plist><dict><key>ExpirationDate</key><date>2027-01-01T00:00:00Z</date><key>Entitlements</key><dict><key>get-task-allow</key><false/></dict><key>TeamIdentifier</key><array><string>BTYVH3R392</string></array><key>Certificate</key><data>Y2VydGlmaWNhdGU=</data></dict></plist>'
    profile = release.decode_plist(REXML::Document.new(xml).root.elements[1])
    assert_equal '2027-01-01T00:00:00Z', profile['ExpirationDate']
    assert_equal false, profile.dig('Entitlements', 'get-task-allow')
    assert_equal ['BTYVH3R392'], profile['TeamIdentifier']
    assert_equal 'certificate', profile['Certificate']
  end

  def test_api_jwt_is_es256_with_short_lived_claims_and_valid_signature
    Dir.mktmpdir do |directory|
      key = OpenSSL::PKey::EC.new('prime256v1').generate_key
      path = File.join(directory, 'test-only-key.p8')
      File.write(path, key.to_pem)
      release = TravelMapRelease.new('ASC_KEY_PATH' => path, 'ASC_KEY_ID' => 'TESTKEY', 'ASC_ISSUER_ID' => 'TESTISSUER')
      token = release.token
      header, payload, signature = token.split('.')
      assert_equal 'ES256', JSON.parse(Base64.urlsafe_decode64(header))['alg']
      claims = JSON.parse(Base64.urlsafe_decode64(payload))
      assert_equal 'TESTISSUER', claims['iss']
      assert_equal 'appstoreconnect-v1', claims['aud']
      assert_equal 900, claims['exp'] - claims['iat']
      raw = Base64.urlsafe_decode64(signature)
      assert_equal 64, raw.bytesize
      der = OpenSSL::ASN1::Sequence.new(raw.unpack('H64H64').map { |hex| OpenSSL::ASN1::Integer.new(OpenSSL::BN.new(hex, 16)) }).to_der
      assert key.dsa_verify_asn1(Digest::SHA256.digest("#{header}.#{payload}"), der)
      refute_includes release.redact(token), token
    end
  end
end
