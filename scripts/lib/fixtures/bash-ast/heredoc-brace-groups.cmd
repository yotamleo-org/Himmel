python3 - <<'EOF'
import re
p='setup.ts'; s=open(p).read()
s=s.replace('''type AccountOpts = { loginPath: string; serviceMode: boolean };
''','''type AccountOpts = { loginPath: string; serviceMode: boolean };
const SET_LOGIN = `bun ${join(import.meta.dir, "server.ts")} --set-login <user>`;
''')
s=s.replace('''    return { status: l ? "set" : "not-set", user: l?.user ?? null, create: !l && !o.serviceMode ? "ui" : "terminal" };
  } catch { return { status: "unreadable", user: null, create: "terminal" }; }''','''    return { status: l ? "set" : "not-set", user: l?.user ?? null, create: !l && !o.serviceMode ? "ui" : "terminal", setLogin: SET_LOGIN };
  } catch { return { status: "unreadable", user: null, create: "terminal", setLogin: SET_LOGIN }; }''')
s=s.replace('fail(403, `service mode: set the login with \\`bun ${join(import.meta.dir, "server.ts")} --set-login <user>\\` from your own terminal`)','fail(403, `service mode: set the login with \\`${SET_LOGIN}\\` from your own terminal`)')
s=s.replace('fail(409, `a login is already set; change it with \\`bun ${join(import.meta.dir, "server.ts")} --set-login <user>\\``)','fail(409, `a login is already set; change it with \\`${SET_LOGIN}\\``)')
open(p,'w').write(s)
p='public/setup.js'; s=open(p).read()
s=s.replace('<code>bun scripts/config-ui/server.ts --set-login &lt;user&gt;</code>','<code>${esc(a.setLogin)}</code>')
open(p,'w').write(s)
p='tests/setup-account.test.ts'; s=open(p).read()
s=s.replace('expect((await b.state()).account).toEqual({ status: "not-set", user: null, create: "ui" });','expect((await b.state()).account).toMatchObject({ status: "not-set", user: null, create: "ui" });')
s=s.replace('expect((await b.state()).account).toEqual({ status: "set", user: "op", create: "terminal" });','expect((await b.state()).account).toMatchObject({ status: "set", user: "op", create: "terminal" });')
s=s.replace('expect((await b.state()).account).toEqual({ status: "not-set", user: null, create: "terminal" });','const acct = (await b.state()).account;\n  expect(acct).toMatchObject({ status: "not-set", user: null, create: "terminal" });\n  expect(acct.setLogin).toBe(`bun ${join(import.meta.dir, "..", "server.ts")} --set-login <user>`);')
s=s.replace('{ status: "not-set", user: null, create: "terminal" } }, {}, {});','{ status: "not-set", user: null, create: "terminal", setLogin: "bun /abs/server.ts --set-login <user>" } }, {}, {});')
s=s.replace('expect(service).toContain("--set-login");','expect(service).toContain("bun /abs/server.ts --set-login &lt;user&gt;");')
open(p,'w').write(s)
EOF
grep -n "SET_LOGIN\|setLogin" setup.ts public/setup.js tests/setup-account.test.ts; bun test tests/setup-account.test.ts tests/setup-secret.test.ts tests/setup-coderabbit.test.ts tests/login.test.ts 2>&1 | grep -E "^\(fail\)| pass$| fail$|error"
