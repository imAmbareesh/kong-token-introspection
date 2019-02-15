local _M = { conf = {} }
local http = require "resty.http"
local pl_stringx = require "pl.stringx"
local cjson = require "cjson.safe"

function _M.error_response(message, status)
    local jsonStr = '{"data":[],"error":{"code":' .. status .. ',"message":"' .. message .. '"}}'
    ngx.header['Content-Type'] = 'application/json'
    ngx.status = status
    ngx.say(jsonStr)
    ngx.exit(status)
end

function _M.introspect_access_token_req(access_token)
    local httpc = http:new()
    local res, err = httpc:request_uri(_M.conf.introspection_endpoint, {
        method = "POST",
        ssl_verify = false,
        body = "token_type_hint=access_token&token=" .. access_token,
        headers = { ["Content-Type"] = "application/x-www-form-urlencoded", }
    })

    if not res then
        return { status = 0 }
    end
    if res.status ~= 200 then
        return { status = res.status }
    end
    return { status = res.status, body = res.body }
end

function _M.introspect_access_token(access_token)
    if _M.conf.token_cache_time > 0 then
        local res, err = kong.cache:get("at:" .. access_token, { ttl = _M.conf.token_cache_time },
                _M.introspect_access_token_req, access_token)
        if err then
            _M.error_response("Unexpected error: " .. err, ngx.HTTP_INTERNAL_SERVER_ERROR)
        end
        return res
    end

    return _M.introspect_access_token_req(access_token)
end

-- TODO: scope-control
function _M.run(conf)
    _M.conf = conf;
    local access_token = ngx.req.get_headers()[_M.conf.token_header]
    if not access_token then
        _M.error_response("Unauthenticated.", ngx.HTTP_UNAUTHORIZED)
    end
    -- replace Bearer prefix
    access_token = pl_stringx.replace(access_token, "Bearer ", "", 1)

    local res = _M.introspect_access_token(access_token)
    if not res then
        _M.error_response("Authorization server error.", ngx.HTTP_INTERNAL_SERVER_ERROR)
    end
    if res.status ~= 200 then
        _M.error_response("The resource owner or authorization server denied the request.", ngx.HTTP_UNAUTHORIZED)
    end

    local data = cjson.decode(res.body)
    ngx.req.set_header("X-Credential-Sub", data["sub"])
    ngx.req.set_header("X-Credential-Scope", data["scope"])
    -- clear token header from req
    ngx.req.clear_header(_M.conf.token_header)
end

return _M