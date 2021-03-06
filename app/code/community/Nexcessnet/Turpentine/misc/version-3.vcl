## Nexcessnet_Turpentine Varnish v3 VCL Template

## Custom C Code

C{
    # @source app/code/community/Nexcessnet/Turpentine/misc/uuid.c
    {{custom_c_code}}
}C

## Imports

import std;

## Custom VCL Logic

{{custom_vcl_include}}

## Backends

{{default_backend}}

{{admin_backend}}

## ACLs

{{crawler_acl}}

{{debug_acl}}

## Custom Subroutines

sub remove_cache_headers {
    # remove cache headers so we can set our own
    unset beresp.http.Cache-Control;
    unset beresp.http.Expires;
    unset beresp.http.Pragma;
    unset beresp.http.Cache;
    unset beresp.http.Age;
}

sub remove_double_slashes {
    # remove double slashes from the URL, for higher cache hit rate
    set req.url = regsub(req.url, "(.*)//+(.*)", "\1/\2");
}

sub generate_session {
    # generate a UUID and set the Cookie header to `frontend=$UUID`, overwrites
    # any other cookies in the header
    C{
        char uuid_buf [50];
        generate_uuid(uuid_buf);
        VRT_SetHdr(sp, HDR_REQ,
            "\030X-Varnish-Faked-Session:",
            uuid_buf,
            vrt_magic_string_end
        );
    }C
    if (req.http.Cookie) {
        # client sent us cookies, just not a frontend cookie. try not to blow
        # away the extra cookies
        std.collect(req.http.Cookie);
        set req.http.Cookie = req.http.X-Varnish-Faked-Session +
            "; " + req.http.Cookie;
    } else {
        set req.http.Cookie = req.http.X-Varnish-Faked-Session;
    }
}

sub generate_session_expires {
    # sets X-Varnish-Cookie-Expires to now + esi_private_ttl in format:
    #   Tue, 19-Feb-2013 00:14:27 GMT
    # this isn't threadsafe but it shouldn't matter in this case
    C{
        time_t now = time(NULL);
        struct tm now_tm = *gmtime(&now);
        now_tm.tm_sec += {{esi_private_ttl}};
        mktime(&now_tm);
        char date_buf [50];
        strftime(date_buf, sizeof(date_buf)-1, "%a, %d-%b-%Y %H:%M:%S %Z", &now_tm);
        VRT_SetHdr(sp, HDR_RESP,
            "\031X-Varnish-Cookie-Expires:",
            date_buf,
            vrt_magic_string_end
        );
    }C
}

## Varnish Subroutines

sub vcl_recv {
    # this always needs to be done so it's up at the top
    if (req.restarts == 0) {
        if (req.http.X-Forwarded-For) {
            set req.http.X-Forwarded-For =
                req.http.X-Forwarded-For + ", " + client.ip;
        } else {
            set req.http.X-Forwarded-For = client.ip;
        }
    }

    # We only deal with GET and HEAD by default
    if (req.request !~ "^(GET|HEAD)$") {
        return (pipe);
    }

    call remove_double_slashes;

    {{normalize_encoding}}
    {{normalize_user_agent}}
    {{normalize_host}}

    # we test this here instead of inside the url base regex section
    # so we can disable caching for the entire site if needed
    if (!{{enable_caching}} || req.http.Authorization) {
        return (pipe);
    }
    # check if the request is for part of magento
    if (req.url ~ "{{url_base_regex}}") {
        # set this so Turpentine can see the request passed through Varnish
        set req.http.X-Turpentine-Secret-Handshake = "{{secret_handshake}}";
        # use the special admin backend and pipe if it's for the admin section
        if (req.url ~ "{{url_base_regex}}{{admin_frontname}}") {
            set req.backend = admin;
            return (pipe);
        }
        # looks like an ESI request, add some extra vars for further processing
        if (req.url ~ "/turpentine/esi/getBlock/") {
            set req.http.X-Varnish-Esi-Method = regsub(
                req.url, ".*/{{esi_method_param}}/(\w+)/.*", "\1");
            set req.http.X-Varnish-Esi-Access = regsub(
                req.url, ".*/{{esi_cache_type_param}}/(\w+)/.*", "\1");

            # throw a forbidden error if debugging is off and a esi block is
            # requested by the user (does not apply to ajax blocks)
            if (req.http.X-Varnish-Esi-Method == "esi" && req.esi_level == 0 &&
                    !({{debug_headers}} || client.ip ~ debug_acl)) {
                error 403 "External ESI requests are not allowed";
            }
        }
        # no frontend cookie was sent to us
        if (req.http.Cookie !~ "frontend=") {
            if (client.ip ~ crawler_acl ||
                    req.http.User-Agent ~ "^(?:{{crawler_user_agent_regex}})$") {
                # it's a crawler, give it a fake cookie
                set req.http.Cookie = "frontend=crawler-session";
            } else {
                # it's a real user, make up a new session for them
                call generate_session;
            }
        }
        if ({{force_cache_static}} &&
                req.url ~ ".*\.(?:{{static_extensions}})(?=\?|&|$)") {
            # don't need cookies for static assets
            unset req.http.Cookie;
            return (lookup);
        }
        # this doesn't need a enable_url_excludes because we can be reasonably
        # certain that cron.php at least will always be in it, so it will
        # never be empty
        if (req.url ~ "{{url_base_regex}}(?:{{url_excludes}})") {
            return (pipe);
        }
        if ({{enable_get_excludes}} &&
                req.url ~ "(?:[?&](?:{{get_param_excludes}})(?=[&=]|$))") {
            # TODO: should this be pass or pipe?
            return (pass);
        }
        # everything else checks out, try and pull from the cache
        return (lookup);
    }
    # else it's not part of magento so do default handling (doesn't help
    # things underneath magento but we can't detect that)
}

sub vcl_pipe {
    # since we're not going to do any stuff to the response we pretend the
    # request didn't pass through Varnish
    unset bereq.http.X-Turpentine-Secret-Handshake;
    set bereq.http.Connection = "close";
}

# sub vcl_pass {
#     return (pass);
# }

sub vcl_hash {
    hash_data(req.url);
    if (req.http.Host) {
        hash_data(req.http.Host);
    } else {
        hash_data(server.ip);
    }
    if (req.http.X-Normalized-User-Agent) {
        hash_data(req.http.X-Normalized-User-Agent);
    }
    if (req.http.Accept-Encoding) {
        # make sure we give back the right encoding
        hash_data(req.http.Accept-Encoding);
    }
    if (req.http.X-Varnish-Esi-Access == "private" &&
            req.http.Cookie ~ "frontend=") {
        hash_data(regsub(req.http.Cookie, "^.*?frontend=([^;]*);*.*$", "\1"));
        {{advanced_session_validation}}

    }
    return (hash);
}

sub vcl_hit {
    # this seems to cause cache object contention issues so removed for now
    # TODO: use obj.hits % something maybe
    # if (obj.hits > 0) {
    #     set obj.ttl = obj.ttl + {{lru_factor}}s;
    # }
}

# sub vcl_miss {
#     return (fetch);
# }

sub vcl_fetch {
    # set the grace period
    set req.grace = {{grace_period}}s;

    # if it's part of magento...
    if (req.url ~ "{{url_base_regex}}") {
        # we handle the Vary stuff ourselves for now, we'll want to actually
        # use this eventually for compatibility with downstream proxies
        # TODO: only remove the User-Agent field from this if it exists
        unset beresp.http.Vary;
        # we pretty much always want to do this
        set beresp.do_gzip = true;

        if (beresp.status != 200 && beresp.status != 404) {
            # pass anything that isn't a 200 or 404
            set beresp.ttl = {{grace_period}}s;
            return (hit_for_pass);
        } else {
            # if Magento sent us a Set-Cookie header, we'll put it somewhere
            # else for now
            if (beresp.http.Set-Cookie) {
                set beresp.http.X-Varnish-Set-Cookie = beresp.http.Set-Cookie;
                unset beresp.http.Set-Cookie;
            }
            # we'll set our own cache headers if we need them
            call remove_cache_headers;

            if (beresp.http.X-Turpentine-Esi == "1") {
                set beresp.do_esi = true;
            }
            if (beresp.http.X-Turpentine-Cache == "0") {
                set beresp.ttl = {{grace_period}}s;
                return (hit_for_pass);
            } else {
                if ({{force_cache_static}} &&
                        bereq.url ~ ".*\.(?:{{static_extensions}})(?=\?|&|$)") {
                    # it's a static asset
                    set beresp.ttl = {{static_ttl}}s;
                    set beresp.http.Cache-Control = "max-age={{static_ttl}}";
                } elseif (req.http.X-Varnish-Esi-Method) {
                    # it's a ESI request
                    if (req.http.X-Varnish-Esi-Access == "private" &&
                            req.http.Cookie ~ "frontend=") {
                        # set this header so we can ban by session from Turpentine
                        set beresp.http.X-Varnish-Session = regsub(req.http.Cookie,
                            "^.*?frontend=([^;]*);*.*$", "\1");
                    }
                    if (req.http.X-Varnish-Esi-Method == "ajax" &&
                            req.http.X-Varnish-Esi-Access == "public") {
                        set beresp.http.Cache-Control = "max-age=" + regsub(
                            req.url, ".*/{{esi_ttl_param}}/(\d+)/.*", "\1");
                    }
                    set beresp.ttl = std.duration(
                        regsub(
                            req.url, ".*/{{esi_ttl_param}}/(\d+)/.*", "\1s"),
                        300s);
                    if (beresp.ttl == 0s) {
                        # this is probably faster than bothering with 0 ttl
                        # cache objects
                        set beresp.ttl = {{grace_period}}s;
                        return (hit_for_pass);
                    }
                } else {
                    {{url_ttls}}
                }
            }
        }
        # we've done what we need to, send to the client
        return (deliver);
    }
    # else it's not part of Magento so use the default Varnish handling
}

sub vcl_deliver {
    if (req.http.X-Varnish-Faked-Session) {
        # need to set the set-cookie header since we just made it out of thin air
        call generate_session_expires;
        set resp.http.Set-Cookie = req.http.X-Varnish-Faked-Session +
            "; expires=" + resp.http.X-Varnish-Cookie-Expires + "; path=" +
            regsub(regsub(req.url, "{{url_base_regex}}.*", "\1"), "/$", "");
        if (req.http.Host) {
            set resp.http.Set-Cookie = resp.http.Set-Cookie +
                "; domain=" + regsub(req.http.Host, ":\d+$", "");
        }
        set resp.http.Set-Cookie = resp.http.Set-Cookie + "; httponly";
        unset resp.http.X-Varnish-Cookie-Expires;
    }
    if ({{debug_headers}} || client.ip ~ debug_acl) {
        # debugging is on, give some extra info
        set resp.http.X-Varnish-Hits = obj.hits;
        set resp.http.X-Varnish-Esi-Method = req.http.X-Varnish-Esi-Method;
        set resp.http.X-Varnish-Esi-Access = req.http.X-Varnish-Esi-Access;
    } else {
        # remove Varnish fingerprints
        unset resp.http.X-Varnish;
        unset resp.http.Via;
        unset resp.http.X-Powered-By;
        unset resp.http.Server;
        unset resp.http.X-Turpentine-Cache;
        unset resp.http.X-Turpentine-Esi;
        unset resp.http.X-Turpentine-Flush-Events;
        unset resp.http.X-Varnish-Session;
        # this header indicates the session that originally generated a cached
        # page. it *must* not be sent to a client in production with lax
        # session validation or that session can be hijacked
        unset resp.http.X-Varnish-Set-Cookie;
    }
}
