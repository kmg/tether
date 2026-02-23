defmodule Tether.WebPush do
  @moduledoc """
  Web Push with aes128gcm encoding (RFC 8291) and VAPID (RFC 8292).

  Replaces `web_push_encryption` which only supports the deprecated aesgcm
  encoding. Apple's push service requires aes128gcm.
  """
  require Logger

  @doc """
  Send a push notification to a subscription.

  Subscription must have: `%{endpoint: "...", keys: %{auth: "...", p256dh: "..."}}`
  """
  def send(message, subscription) when is_binary(message) do
    vapid = Application.fetch_env!(:web_push_encryption, :vapid_details)

    audience = extract_audience(subscription.endpoint)
    jwt = build_vapid_jwt(audience, vapid)
    vapid_key = vapid[:public_key]

    encrypted = encrypt_payload(message, subscription)

    headers = [
      {~c"Authorization", to_charlist("vapid t=#{jwt}, k=#{vapid_key}")},
      {~c"Content-Encoding", ~c"aes128gcm"},
      {~c"TTL", ~c"86400"}
    ]

    :httpc.request(
      :post,
      {to_charlist(subscription.endpoint), headers, ~c"application/octet-stream", encrypted},
      [ssl: ssl_opts()],
      []
    )
    |> handle_response()
  end

  # --- VAPID JWT (RFC 8292) ---

  defp build_vapid_jwt(audience, vapid) do
    header = %{"alg" => "ES256", "typ" => "JWT"}

    claims = %{
      "aud" => audience,
      "exp" => System.system_time(:second) + 12 * 3600,
      "sub" => vapid[:subject] || "mailto:tether@example.com"
    }

    header_b64 = Base.url_encode64(Jason.encode!(header), padding: false)
    claims_b64 = Base.url_encode64(Jason.encode!(claims), padding: false)
    signing_input = "#{header_b64}.#{claims_b64}"

    private_key = Base.url_decode64!(vapid[:private_key], padding: false)
    signature = sign_es256(signing_input, private_key)

    "#{signing_input}.#{Base.url_encode64(signature, padding: false)}"
  end

  defp sign_es256(input, private_key_raw) do
    # Sign with ECDSA P-256 SHA-256, get DER-encoded signature
    der_sig = :crypto.sign(:ecdsa, :sha256, input, [private_key_raw, :secp256r1])
    # Convert DER to raw r||s format (64 bytes) per JWS spec
    der_to_raw(der_sig)
  end

  defp der_to_raw(<<0x30, _len, 0x02, r_len, r::binary-size(r_len), 0x02, s_len, s::binary>>)
       when byte_size(s) == s_len do
    pad_to_32(r) <> pad_to_32(s)
  end

  defp pad_to_32(bin) when byte_size(bin) > 32, do: binary_part(bin, byte_size(bin) - 32, 32)

  defp pad_to_32(bin) when byte_size(bin) < 32,
    do: :binary.copy(<<0>>, 32 - byte_size(bin)) <> bin

  defp pad_to_32(bin), do: bin

  # --- aes128gcm Encryption (RFC 8291 + RFC 8188) ---

  defp encrypt_payload(plaintext, subscription) do
    # Decode client keys from subscription
    client_public = Base.url_decode64!(subscription.keys.p256dh, padding: false)
    client_auth = Base.url_decode64!(subscription.keys.auth, padding: false)

    # Generate ephemeral server key pair
    {server_public, server_private} = :crypto.generate_key(:ecdh, :prime256v1)

    # ECDH shared secret
    shared_secret = :crypto.compute_key(:ecdh, client_public, server_private, :prime256v1)

    # Generate salt
    salt = :crypto.strong_rand_bytes(16)

    # Key derivation per RFC 8291 Section 3.4
    # IKM = HKDF(client_auth, shared_secret, "WebPush: info\0" || client_public || server_public, 32)
    info_context = "WebPush: info\0" <> client_public <> server_public
    ikm = hkdf(client_auth, shared_secret, info_context, 32)

    # Content Encryption Key: HKDF(salt, ikm, "Content-Encoding: aes128gcm\0", 16)
    cek = hkdf(salt, ikm, "Content-Encoding: aes128gcm\0", 16)

    # Nonce: HKDF(salt, ikm, "Content-Encoding: nonce\0", 12)
    nonce = hkdf(salt, ikm, "Content-Encoding: nonce\0", 12)

    # Pad plaintext: content || delimiter(0x02) || padding(0x00...)
    # Single record, so delimiter is 0x02 (final record)
    padded = plaintext <> <<2>>

    # Encrypt with AES-128-GCM
    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_128_gcm,
        cek,
        nonce,
        padded,
        <<>>,
        16,
        true
      )

    # Build aes128gcm payload: header || ciphertext || tag
    # Header: salt(16) || rs(4, big-endian uint32) || idlen(1) || keyid(65)
    # Record size (rs) in header — max bytes per record, 4096 is standard
    header = salt <> <<4096::unsigned-big-32>> <> <<65::unsigned-8>> <> server_public

    header <> ciphertext <> tag
  end

  # HKDF-SHA256 (extract + expand, single output block)
  defp hkdf(salt, ikm, info, length) do
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    # Expand: T(1) = HMAC(PRK, info || 0x01)
    output = :crypto.mac(:hmac, :sha256, prk, info <> <<1>>)
    binary_part(output, 0, length)
  end

  # --- Helpers ---

  defp extract_audience(endpoint) do
    uri = URI.parse(endpoint)
    "#{uri.scheme}://#{uri.host}"
  end

  defp ssl_opts do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      versions: [:"tlsv1.2", :"tlsv1.3"]
    ]
  end

  defp handle_response({:ok, {{_, status, _}, _headers, body}}) when status in 200..299 do
    {:ok, %{status_code: status, body: to_string(body)}}
  end

  defp handle_response({:ok, {{_, status, _}, _headers, body}}) do
    {:ok, %{status_code: status, body: to_string(body)}}
  end

  defp handle_response({:error, reason}) do
    {:error, reason}
  end
end
