function value = frontendHash(payload)
%FRONTENDHASH Stable SHA-256 of a JSON-serializable configuration/coefficients.
    bytes = unicode2native(jsonencode(payload),'UTF-8');
    engine = java.security.MessageDigest.getInstance('SHA-256');
    engine.update(bytes);
    value = lower(reshape(dec2hex(typecast(engine.digest(),'uint8'),2).',1,[]));
end
