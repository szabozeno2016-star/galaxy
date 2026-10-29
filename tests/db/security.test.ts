import { describe, test, expect } from "bun:test";
import { db, makeUser, as, rpc, perm, makeServer, join, send, count } from "./helpers";

describe("accounts", () => {
  test("sign-up creates a profile and private settings", async () => {
    const u = await makeUser("Nova");
    expect(u.username).toMatch(/^nova_/);
    expect(await count(u.id, "select * from public.user_settings where user_id = auth.uid()")).toBe(1);
  });

  test("usernames are made unique and valid", async () => {
    const a = crypto.randomUUID();
    const b = crypto.randomUUID();
    await db`insert into auth.users (id, email, raw_user_meta_data) values (${a}, 'x@x.test', ${{ username: "Star Dust!!" }})`;
    await db`insert into auth.users (id, email, raw_user_meta_data) values (${b}, 'y@x.test', ${{ username: "star dust" }})`;
    const [pa] = await db`select username from profiles where id = ${a}`;
    const [pb] = await db`select username from profiles where id = ${b}`;
    expect(pa.username).toMatch(/^[a-z0-9_.]+$/);
    expect(pa.username).not.toBe(pb.username);
  });

  test("people can't promote themselves to admin or edit others", async () => {
    const u = await makeUser();
    const v = await makeUser();
    await expect(as(u.id, (tx) => tx`update public.profiles set is_admin = true where id = ${u.id}`)).rejects.toThrow(/permission denied/);
    const changed = await as(u.id, (tx) => tx`update public.profiles set bio = 'hacked' where id = ${v.id} returning id`);
    expect(changed.length).toBe(0);
    const ok = await as(u.id, (tx) => tx`update public.profiles set bio = 'hi', banner_color = '#123456' where id = ${u.id} returning id`);
    expect(ok.length).toBe(1);
  });

  test("settings are private", async () => {
    const u = await makeUser();
    const v = await makeUser();
    expect(await count(v.id, "select * from public.user_settings where user_id = $1", u.id)).toBe(0);
  });

  test("anonymous visitors can't read anything", async () => {
    await expect(as(null, (tx) => tx`select * from public.profiles limit 1`)).rejects.toThrow(/permission denied/);
    await expect(as(null, (tx) => tx`select * from public.messages limit 1`)).rejects.toThrow(/permission denied/);
  });

  test("account deletion removes the profile and owned servers", async () => {
    const u = await makeUser();
    const { sid } = await makeServer(u.id);
    await rpc(u.id, "select public.delete_my_account()");
    expect((await db`select 1 from profiles where id = ${u.id}`).length).toBe(0);
    expect((await db`select 1 from servers where id = ${sid}`).length).toBe(0);
  });

  test("data export includes my own data", async () => {
    const u = await makeUser();
    const out = await rpc<any>(u.id, "select public.export_my_data()");
    expect(out.profile.id).toBe(u.id);
  });
});

describe("friends and blocking", () => {
  test("request → accept, both see the friendship", async () => {
    const a = await makeUser();
    const b = await makeUser();
    const r = await rpc<any>(a.id, "select public.send_friend_request($1)", b.username);
    expect(r.status).toBe("sent");
    expect(await count(b.id, "select * from public.notifications where type = 'friend_request'")).toBe(1);
    await rpc(b.id, "select public.respond_friend_request($1, true)", a.id);
    expect(await count(a.id, "select * from public.friends where user_id = auth.uid()")).toBe(1);
    expect(await count(b.id, "select * from public.friends where user_id = auth.uid()")).toBe(1);
  });

  test("a request back to someone who asked first accepts it", async () => {
    const a = await makeUser();
    const b = await makeUser();
    await rpc(a.id, "select public.send_friend_request($1)", b.username);
    const r = await rpc<any>(b.id, "select public.send_friend_request($1)", a.username);
    expect(r.status).toBe("accepted");
  });

  test("blocking removes friendship and stops requests and DMs", async () => {
    const a = await makeUser();
    const b = await makeUser();
    await rpc(a.id, "select public.send_friend_request($1)", b.username);
    await rpc(b.id, "select public.respond_friend_request($1, true)", a.id);
    const dm = await rpc<string>(a.id, "select public.open_dm($1)", b.id);
    await rpc(b.id, "select public.block_user($1)", a.id);
    expect(await count(a.id, "select * from public.friends where user_id = auth.uid()")).toBe(0);
    await expect(rpc(a.id, "select public.send_friend_request($1)", b.username)).rejects.toThrow(/isn't accepting/);
    await expect(send(a.id, dm, "hello?")).rejects.toThrow();
  });

  test("friend request privacy setting is enforced", async () => {
    const a = await makeUser();
    const b = await makeUser();
    await as(b.id, (tx) => tx`update public.user_settings set friend_requests_from = 'none' where user_id = auth.uid()`);
    await expect(rpc(a.id, "select public.send_friend_request($1)", b.username)).rejects.toThrow(/isn't accepting friend requests/);
  });
});

describe("direct messages", () => {
  test("DMs are private to the two people", async () => {
    const a = await makeUser();
    const b = await makeUser();
    const c = await makeUser();
    const dm = await rpc<string>(a.id, "select public.open_dm($1)", b.id);
    expect(await rpc<string>(b.id, "select public.open_dm($1)", a.id)).toBe(dm);
    await send(a.id, dm, "secret");
    expect(await count(b.id, "select * from public.messages where channel_id = $1", dm)).toBe(1);
    expect(await count(c.id, "select * from public.messages where channel_id = $1", dm)).toBe(0);
    await expect(send(c.id, dm, "let me in")).rejects.toThrow();
  });

  test("strangers land in message requests", async () => {
    const a = await makeUser();
    const b = await makeUser();
    const dm = await rpc<string>(a.id, "select public.open_dm($1)", b.id);
    const accepted = await rpc<boolean>(b.id, "select accepted from public.channel_recipients where channel_id = $1 and user_id = auth.uid()", dm);
    expect(accepted).toBe(false);
  });

  test("friends-only DM setting is enforced", async () => {
    const a = await makeUser();
    const b = await makeUser();
    await as(b.id, (tx) => tx`update public.user_settings set allow_dms = 'friends' where user_id = auth.uid()`);
    await expect(rpc(a.id, "select public.open_dm($1)", b.id)).rejects.toThrow(/only accepts messages from friends/);
  });

  test("group DMs only accept friends", async () => {
    const a = await makeUser();
    const b = await makeUser();
    const c = await makeUser();
    await rpc(a.id, "select public.send_friend_request($1)", b.username);
    await rpc(b.id, "select public.respond_friend_request($1, true)", a.id);
    await expect(rpc(a.id, "select public.create_group_dm($1::uuid[], 'x')", `{${b.id},${c.id}}`)).rejects.toThrow(/only add friends/);
    const g = await rpc<string>(a.id, "select public.create_group_dm($1::uuid[], 'pals')", `{${b.id}}`);
    expect(await count(b.id, "select * from public.channels where id = $1", g)).toBe(1);
  });
});

describe("servers and permissions", () => {
  test("creating a server sets up roles, channels and membership", async () => {
    const o = await makeUser();
    const { sid } = await makeServer(o.id, "gaming");
    expect(await count(o.id, "select * from public.channels where server_id = $1", sid)).toBeGreaterThan(4);
    expect(await count(o.id, "select * from public.roles where server_id = $1 and is_default", sid)).toBe(1);
    expect(await rpc<number>(o.id, "select member_count from public.servers where id = $1", sid)).toBe(1);
  });

  test("outsiders can't see a private server or its messages", async () => {
    const o = await makeUser();
    const x = await makeUser();
    const { sid, general } = await makeServer(o.id);
    await send(o.id, general, "members only");
    expect(await count(x.id, "select * from public.servers where id = $1", sid)).toBe(0);
    expect(await count(x.id, "select * from public.channels where server_id = $1", sid)).toBe(0);
    expect(await count(x.id, "select * from public.messages where channel_id = $1", general)).toBe(0);
    await expect(send(x.id, general, "hi")).rejects.toThrow();
  });

  test("joining with an invite works; bans and expired invites don't", async () => {
    const o = await makeUser();
    const m = await makeUser();
    const banned = await makeUser();
    const { sid, code, general } = await makeServer(o.id);
    const r = await join(m.id, code);
    expect(r.status).toBe("joined");
    expect(await count(m.id, "select * from public.messages where channel_id = $1 and type = 'join'", general)).toBe(1);
    await join(banned.id, code);
    await rpc(o.id, "select public.ban_member($1, $2, 'spam', 0)", sid, banned.id);
    await expect(join(banned.id, code)).rejects.toThrow(/banned/);
    const expired = await rpc<string>(o.id,
      "insert into public.invites (server_id, created_by, expires_at) values ($1, auth.uid(), now() - interval '1 minute') returning code", sid);
    const late = await makeUser();
    await expect(join(late.id, expired)).rejects.toThrow(/expired/);
  });

  test("invite usage limits", async () => {
    const o = await makeUser();
    const { sid } = await makeServer(o.id);
    const code = await rpc<string>(o.id, "insert into public.invites (server_id, created_by, max_uses) values ($1, auth.uid(), 1) returning code", sid);
    await join((await makeUser()).id, code);
    await expect(join((await makeUser()).id, code)).rejects.toThrow(/expired/);
  });

  test("private channel: hidden from @everyone, visible to the allowed role", async () => {
    const o = await makeUser();
    const mod = await makeUser();
    const pleb = await makeUser();
    const { sid, code } = await makeServer(o.id);
    await join(mod.id, code);
    await join(pleb.id, code);
    const role = await rpc<string>(o.id, "insert into public.roles (server_id, name, permissions, position) values ($1, 'Mods', 0, 1) returning id", sid);
    await rpc(o.id, "select public.set_member_roles($1, $2, $3::uuid[])", sid, mod.id, `{${role}}`);
    const secret = await rpc<string>(o.id, "select public.create_channel($1, 'mod-chat', 'text', null, true, $2::uuid[])", sid, `{${role}}`);
    await send(o.id, secret, "plans");
    expect(await count(mod.id, "select * from public.messages where channel_id = $1", secret)).toBe(1);
    expect(await count(pleb.id, "select * from public.messages where channel_id = $1", secret)).toBe(0);
    expect(await count(pleb.id, "select * from public.channels where id = $1", secret)).toBe(0);
  });

  test("channel overrides: deny send for a role, allow for one member", async () => {
    const o = await makeUser();
    const a = await makeUser();
    const b = await makeUser();
    const { sid, general, everyone, code } = await makeServer(o.id);
    await join(a.id, code);
    await join(b.id, code);
    await rpc(o.id, "select public.set_channel_sync($1, false)", general);
    await as(o.id, (tx) => tx`insert into public.channel_overrides (channel_id, server_id, target_type, target_id, allow, deny)
      values (${general}, ${sid}, 'role', ${everyone}, 0, ${perm("SEND_MESSAGES").toString()})`);
    await as(o.id, (tx) => tx`insert into public.channel_overrides (channel_id, server_id, target_type, target_id, allow, deny)
      values (${general}, ${sid}, 'member', ${a.id}, ${perm("SEND_MESSAGES").toString()}, 0)`);
    await send(a.id, general, "I'm allowed");
    await expect(send(b.id, general, "me too?")).rejects.toThrow();
    expect(await count(b.id, "select * from public.messages where channel_id = $1", general)).toBeGreaterThan(0);
  });

  test("announcement channels are read-only for regular members", async () => {
    const o = await makeUser();
    const m = await makeUser();
    const { sid, code } = await makeServer(o.id);
    await join(m.id, code);
    const ann = await rpc<string>(o.id, "select public.create_channel($1, 'news', 'announcement')", sid);
    await send(o.id, ann, "big news");
    await expect(send(m.id, ann, "reply")).rejects.toThrow();
  });

  test("timeouts stop sending until they expire", async () => {
    const o = await makeUser();
    const m = await makeUser();
    const { sid, general, code } = await makeServer(o.id);
    await join(m.id, code);
    await rpc(o.id, "select public.timeout_member($1, $2, 10, 'cool off')", sid, m.id);
    await expect(send(m.id, general, "hello")).rejects.toThrow();
    expect(await count(m.id, "select * from public.notifications where type = 'moderation'")).toBe(1);
    await rpc(o.id, "select public.timeout_member($1, $2, 0, null)", sid, m.id);
    await send(m.id, general, "back");
  });

  test("role hierarchy limits moderators", async () => {
    const o = await makeUser();
    const mod = await makeUser();
    const senior = await makeUser();
    const pleb = await makeUser();
    const { sid, code } = await makeServer(o.id);
    for (const u of [mod, senior, pleb]) await join(u.id, code);
    const modPerms = (perm("KICK_MEMBERS") | perm("MANAGE_ROLES") | perm("MODERATE_MEMBERS")).toString();
    const modRole = await rpc<string>(o.id, "insert into public.roles (server_id, name, permissions, position) values ($1, 'Mod', $2, 2) returning id", sid, modPerms);
    const seniorRole = await rpc<string>(o.id, "insert into public.roles (server_id, name, permissions, position) values ($1, 'Senior', 0, 5) returning id", sid);
    await rpc(o.id, "select public.set_member_roles($1, $2, $3::uuid[])", sid, mod.id, `{${modRole}}`);
    await rpc(o.id, "select public.set_member_roles($1, $2, $3::uuid[])", sid, senior.id, `{${seniorRole}}`);
    await expect(rpc(mod.id, "select public.kick_member($1, $2, null)", sid, senior.id)).rejects.toThrow(/below yours/);
    await expect(rpc(mod.id, "select public.kick_member($1, $2, null)", sid, o.id)).rejects.toThrow();
    await expect(rpc(mod.id, "select public.set_member_roles($1, $2, $3::uuid[])", sid, pleb.id, `{${seniorRole}}`)).rejects.toThrow();
    await expect(as(mod.id, (tx) => tx`insert into public.roles (server_id, name, permissions, position)
      values (${sid}, 'Admin', ${perm("ADMINISTRATOR").toString()}, 1)`)).rejects.toThrow();
    await rpc(mod.id, "select public.kick_member($1, $2, 'bye')", sid, pleb.id);
    expect(await count(o.id, "select * from public.members where server_id = $1 and user_id = $2", sid, pleb.id)).toBe(0);
    expect(await count(o.id, "select * from public.audit_logs where server_id = $1 and action = 'member.kick'", sid)).toBe(1);
  });

  test("admins get everything; members can't change server settings", async () => {
    const o = await makeUser();
    const a = await makeUser();
    const m = await makeUser();
    const { sid, code } = await makeServer(o.id);
    await join(a.id, code);
    await join(m.id, code);
    const adminRole = await rpc<string>(o.id, "insert into public.roles (server_id, name, permissions, position) values ($1, 'Admin', $2, 3) returning id", sid, perm("ADMINISTRATOR").toString());
    await rpc(o.id, "select public.set_member_roles($1, $2, $3::uuid[])", sid, a.id, `{${adminRole}}`);
    const upd = await as(m.id, (tx) => tx`update public.servers set name = 'pwned' where id = ${sid} returning id`);
    expect(upd.length).toBe(0);
    const ok = await as(a.id, (tx) => tx`update public.servers set name = 'Renamed' where id = ${sid} returning id`);
    expect(ok.length).toBe(1);
    await expect(as(a.id, (tx) => tx`update public.servers set owner_id = ${a.id} where id = ${sid}`)).rejects.toThrow(/permission denied/);
  });

  test("owner can transfer ownership; non-owners cannot", async () => {
    const o = await makeUser();
    const m = await makeUser();
    const { sid, code } = await makeServer(o.id);
    await join(m.id, code);
    await expect(rpc(m.id, "select public.transfer_ownership($1, $2)", sid, m.id)).rejects.toThrow(/Only the owner/);
    await rpc(o.id, "select public.transfer_ownership($1, $2)", sid, m.id);
    expect(await rpc<string>(m.id, "select owner_id from public.servers where id = $1", sid)).toBe(m.id);
  });

  test("audit log is only visible with View Audit Log", async () => {
    const o = await makeUser();
    const m = await makeUser();
    const { sid, code } = await makeServer(o.id);
    await join(m.id, code);
    await as(o.id, (tx) => tx`update public.servers set description = 'new' where id = ${sid}`);
    expect(await count(o.id, "select * from public.audit_logs where server_id = $1", sid)).toBeGreaterThan(0);
    expect(await count(m.id, "select * from public.audit_logs where server_id = $1", sid)).toBe(0);
  });

  test("my_channel_perms matches what the database enforces", async () => {
    const o = await makeUser();
    const m = await makeUser();
    const { sid, general, code } = await makeServer(o.id);
    await join(m.id, code);
    const p = BigInt(await rpc<string>(m.id, "select perms from public.my_channel_perms() where channel_id = $1", general));
    expect(p & perm("SEND_MESSAGES")).toBeTruthy();
    expect(p & perm("MANAGE_MESSAGES")).toBeFalsy();
    const op = BigInt(await rpc<string>(o.id, "select perms from public.my_channel_perms() where channel_id = $1", general));
    expect(op).toBe((1n << 30n) - 1n);
  });

  test("discovery only lists public servers", async () => {
    const o = await makeUser();
    const x = await makeUser();
    const { sid } = await makeServer(o.id);
    const name = "Hidden" + Math.random().toString(36).slice(2, 7);
    await as(o.id, (tx) => tx`update public.servers set name = ${name} where id = ${sid}`);
    expect(await count(x.id, "select * from public.discover_servers($1)", name)).toBe(0);
    await as(o.id, (tx) => tx`update public.servers set is_public = true where id = ${sid}`);
    expect(await count(x.id, "select * from public.discover_servers($1)", name)).toBe(1);
    const r = await rpc<any>(x.id, "select public.join_public_server($1)", sid);
    expect(r.status).toBe("joined");
  });

  test("approval-required servers create a pending application", async () => {
    const o = await makeUser();
    const x = await makeUser();
    const { sid, code } = await makeServer(o.id);
    await as(o.id, (tx) => tx`update public.servers set require_approval = true where id = ${sid}`);
    const r = await rpc<any>(x.id, "select public.join_server($1, $2::jsonb)", code, ["I like stars"]);
    expect(await rpc<string>(o.id, "select jsonb_typeof(answers) from public.join_requests where server_id = $1", sid)).toBe("array");
    expect(r.status).toBe("pending");
    expect(await count(x.id, "select * from public.servers where id = $1", sid)).toBe(0);
    await rpc(o.id, "select public.respond_join_request($1, $2, true)", sid, x.id);
    expect(await count(x.id, "select * from public.servers where id = $1", sid)).toBe(1);
  });
});

describe("messages", () => {
  test("you can't post as someone else or edit their messages", async () => {
    const o = await makeUser();
    const m = await makeUser();
    const { general, code } = await makeServer(o.id);
    await join(m.id, code);
    await expect(as(m.id, (tx) => tx`insert into public.messages (channel_id, author_id, content) values (${general}, ${o.id}, 'fake')`)).rejects.toThrow();
    const id = await send(o.id, general, "original");
    const r = await as(m.id, (tx) => tx`update public.messages set content = 'changed' where id = ${id} returning id`);
    expect(r.length).toBe(0);
    await as(o.id, (tx) => tx`update public.messages set content = 'edited' where id = ${id}`);
    const edited = await rpc<any>(o.id, "select content, edited_at from public.messages where id = $1", id);
    expect(edited.content).toBe("edited");
    expect(edited.edited_at).not.toBeNull();
    expect(await count(o.id, "select * from public.message_edits where message_id = $1", id)).toBe(1);
  });

  test("pinned can't be set directly; moderators pin through the function", async () => {
    const o = await makeUser();
    const m = await makeUser();
    const { general, code } = await makeServer(o.id);
    await join(m.id, code);
    const id = await send(m.id, general, "pin me");
    await expect(as(m.id, (tx) => tx`update public.messages set pinned = true where id = ${id}`)).rejects.toThrow(/permission denied/);
    await expect(rpc(m.id, "select public.pin_message($1, true)", id)).rejects.toThrow(/permission/);
    await rpc(o.id, "select public.pin_message($1, true)", id);
    expect(await rpc<boolean>(m.id, "select pinned from public.messages where id = $1", id)).toBe(true);
  });

  test("moderators delete others' messages; members can't", async () => {
    const o = await makeUser();
    const a = await makeUser();
    const b = await makeUser();
    const { general, code } = await makeServer(o.id);
    await join(a.id, code);
    await join(b.id, code);
    const id = await send(a.id, general, "oops");
    const r = await as(b.id, (tx) => tx`delete from public.messages where id = ${id} returning id`);
    expect(r.length).toBe(0);
    const r2 = await as(o.id, (tx) => tx`delete from public.messages where id = ${id} returning id`);
    expect(r2.length).toBe(1);
  });

  test("mentions and replies create notifications for people who can see them", async () => {
    const o = await makeUser();
    const m = await makeUser();
    const { general, code } = await makeServer(o.id);
    await join(m.id, code);
    const first = await send(m.id, general, "question");
    await send(o.id, general, `hey <@${m.id}>`);
    await send(o.id, general, "answer", { reply_to: first });
    expect(await count(m.id, "select * from public.notifications where type = 'mention'")).toBe(1);
    expect(await count(m.id, "select * from public.notifications where type = 'reply'")).toBe(1);
    const unread = await rpc<any>(m.id, "select mention_count from public.my_unreads() where channel_id = $1", general);
    expect(Number(unread)).toBe(2);
    await rpc(m.id, "select public.mark_read($1)", general);
    expect(await count(m.id, "select * from public.my_unreads() where channel_id = $1", general)).toBe(0);
  });

  test("@everyone only works with permission", async () => {
    const o = await makeUser();
    const m = await makeUser();
    const { general, code } = await makeServer(o.id);
    await join(m.id, code);
    const id = await send(m.id, general, "@everyone look");
    expect(await rpc<boolean>(m.id, "select mention_everyone from public.messages where id = $1", id)).toBe(false);
    const id2 = await send(o.id, general, "@everyone real news");
    expect(await rpc<boolean>(o.id, "select mention_everyone from public.messages where id = $1", id2)).toBe(true);
    expect(await count(m.id, "select * from public.notifications where message_id = $1", id2)).toBe(1);
  });

  test("slow mode, rate limit and AutoMod", async () => {
    const o = await makeUser();
    const m = await makeUser();
    const { sid, general, code } = await makeServer(o.id);
    await join(m.id, code);
    await as(o.id, (tx) => tx`update public.channels set slowmode = 30 where id = ${general}`);
    await send(m.id, general, "one");
    await expect(send(m.id, general, "two")).rejects.toThrow(/Slow mode/);
    await send(o.id, general, "owners skip slow mode");
    await send(o.id, general, "still fine");
    await as(o.id, (tx) => tx`update public.channels set slowmode = 0 where id = ${general}`);
    await as(o.id, (tx) => tx`update public.servers set automod_words = '{badword}' where id = ${sid}`);
    const m2 = await makeUser();
    await join(m2.id, code);
    await expect(send(m2.id, general, "this has BadWord in it")).rejects.toThrow(/AutoMod/);
    const spammer = await makeUser();
    await join(spammer.id, code);
    let failed = false;
    for (let i = 0; i < 12; i++) {
      try { await send(spammer.id, general, "spam " + i); } catch (e: any) { failed = /too quickly/.test(e.message); break; }
    }
    expect(failed).toBe(true);
  });

  test("message length limit", async () => {
    const o = await makeUser();
    const { general } = await makeServer(o.id);
    await send(o.id, general, "x".repeat(4000));
    await expect(send(o.id, general, "x".repeat(4001))).rejects.toThrow();
  });

  test("reactions follow channel access", async () => {
    const o = await makeUser();
    const m = await makeUser();
    const x = await makeUser();
    const { general, code } = await makeServer(o.id);
    await join(m.id, code);
    const id = await send(o.id, general, "react!");
    await as(m.id, (tx) => tx`insert into public.reactions (message_id, channel_id, user_id, emoji) values (${id}, ${general}, ${m.id}, '🌌')`);
    await expect(as(x.id, (tx) => tx`insert into public.reactions (message_id, channel_id, user_id, emoji) values (${id}, ${general}, ${x.id}, '🌌')`)).rejects.toThrow();
    expect(await count(x.id, "select * from public.reactions where message_id = $1", id)).toBe(0);
    expect(await count(m.id, "select * from public.reactions where message_id = $1", id)).toBe(1);
  });

  test("polls: one vote unless multiple choice", async () => {
    const o = await makeUser();
    const { general } = await makeServer(o.id);
    const id = await send(o.id, general, "", { poll: { question: "Best planet?", answers: [{ text: "Saturn" }, { text: "Neptune" }], duration_hours: 24 } });
    await as(o.id, (tx) => tx`insert into public.poll_votes (message_id, channel_id, user_id, answer_id) values (${id}, ${general}, ${o.id}, 0)`);
    await as(o.id, (tx) => tx`insert into public.poll_votes (message_id, channel_id, user_id, answer_id) values (${id}, ${general}, ${o.id}, 1)`);
    expect(await count(o.id, "select * from public.poll_votes where message_id = $1", id)).toBe(1);
    await expect(as(o.id, (tx) => tx`insert into public.poll_votes (message_id, channel_id, user_id, answer_id) values (${id}, ${general}, ${o.id}, 5)`)).rejects.toThrow(/isn't part/);
  });

  test("threads inherit access and forum posts need a message", async () => {
    const o = await makeUser();
    const m = await makeUser();
    const x = await makeUser();
    const { sid, general, code } = await makeServer(o.id);
    await join(m.id, code);
    const starter = await send(m.id, general, "let's discuss");
    const t = await rpc<string>(m.id, "select public.create_thread($1, 'Discussion', $2)", general, starter);
    await send(o.id, t, "in the thread");
    expect(await count(m.id, "select * from public.messages where channel_id = $1", t)).toBe(1);
    expect(await count(x.id, "select * from public.messages where channel_id = $1", t)).toBe(0);
    const forum = await rpc<string>(o.id, "select public.create_channel($1, 'ideas', 'forum')", sid);
    await expect(rpc(m.id, "select public.create_thread($1, 'Empty post')", forum)).rejects.toThrow(/need a message/);
    const post = await rpc<string>(m.id, "select public.create_thread($1, 'Idea', null, 'Dark mode please')", forum);
    expect(await count(o.id, "select * from public.messages where channel_id = $1", post)).toBe(1);
  });

  test("forwarding needs read access to the source and send access to the target", async () => {
    const o = await makeUser();
    const m = await makeUser();
    const { general, code } = await makeServer(o.id);
    const other = await makeServer(o.id);
    await join(m.id, code);
    const id = await send(o.id, general, "share this");
    await expect(rpc(m.id, "select public.forward_message($1, $2, '')", id, other.general)).rejects.toThrow();
    const dm = await rpc<string>(m.id, "select public.open_dm($1)", o.id);
    const fwd = await rpc<string>(m.id, "select public.forward_message($1, $2, 'look')", id, dm);
    const content = await rpc<any>(o.id, "select forwarded->>'content' from public.messages where id = $1", fwd);
    expect(content).toBe("share this");
  });
});

describe("search privacy", () => {
  test("search never returns messages from channels you can't read", async () => {
    const o = await makeUser();
    const m = await makeUser();
    const x = await makeUser();
    const { sid, general, code } = await makeServer(o.id);
    await join(m.id, code);
    const word = "nebula" + Math.random().toString(36).slice(2, 8);
    const secret = await rpc<string>(o.id, "select public.create_channel($1, 'staff', 'text', null, true)", sid);
    await send(o.id, general, `public ${word}`);
    await send(o.id, secret, `private ${word}`);
    expect(await count(o.id, "select * from public.search_messages($1)", word)).toBe(2);
    expect(await count(m.id, "select * from public.search_messages($1)", word)).toBe(1);
    expect(await count(x.id, "select * from public.search_messages($1)", word)).toBe(0);
    expect(await count(m.id, "select * from public.search_messages($1, null, $2)", word, secret)).toBe(0);
  });
});

describe("files", () => {
  test("attachment paths are checked and files are only readable by people who can read the message", async () => {
    const o = await makeUser();
    const m = await makeUser();
    const x = await makeUser();
    const { general, code } = await makeServer(o.id);
    await join(m.id, code);
    const path = `${general}/${o.id}/abc/photo.png`;
    await as(o.id, (tx) => tx`insert into storage.objects (bucket_id, name) values ('attachments', ${path})`);
    await expect(as(x.id, (tx) => tx`insert into storage.objects (bucket_id, name) values ('attachments', ${`${general}/${x.id}/abc/evil.png`})`)).rejects.toThrow();
    await expect(as(m.id, (tx) => tx`insert into storage.objects (bucket_id, name) values ('attachments', ${`${general}/${o.id}/zzz/spoof.png`})`)).rejects.toThrow();
    await send(o.id, general, "", { attachments: [{ path, name: "photo.png", size: 1000, type: "image/png" }] });
    await expect(send(m.id, general, "", { attachments: [{ path, name: "stolen.png", size: 1, type: "image/png" }] })).rejects.toThrow(/couldn't be attached/);
    expect(await count(m.id, "select * from storage.objects where name = $1", path)).toBe(1);
    expect(await count(x.id, "select * from storage.objects where name = $1", path)).toBe(0);
  });

  test("media uploads only go into your own folder", async () => {
    const u = await makeUser();
    await as(u.id, (tx) => tx`insert into storage.objects (bucket_id, name) values ('media', ${`${u.id}/avatar.png`})`);
    await expect(as(u.id, (tx) => tx`insert into storage.objects (bucket_id, name) values ('media', ${`${crypto.randomUUID()}/avatar.png`})`)).rejects.toThrow();
  });
});

describe("realtime authorisation", () => {
  test("topics are limited to people who belong there", async () => {
    const o = await makeUser();
    const m = await makeUser();
    const x = await makeUser();
    const { sid, general, code } = await makeServer(o.id);
    await join(m.id, code);
    const allowed = (uid: string, topic: string, write = false) =>
      rpc<boolean>(uid, "select public.realtime_allowed($1, $2)", topic, write);
    expect(await allowed(m.id, `server:${sid}`)).toBe(true);
    expect(await allowed(x.id, `server:${sid}`)).toBe(false);
    expect(await allowed(m.id, `channel:${general}`)).toBe(true);
    expect(await allowed(x.id, `voice:${general}`)).toBe(false);
    expect(await allowed(m.id, `user:${m.id}`)).toBe(true);
    expect(await allowed(x.id, `user:${m.id}`)).toBe(false);
    expect(await allowed(x.id, `user:${m.id}`, true)).toBe(false);
    const rows = await as(x.id, (tx) => tx`select * from realtime.messages`, `server:${sid}`);
    expect(rows.length).toBe(0);
    await expect(as(x.id, (tx) => tx`insert into realtime.messages (topic, extension, payload) values (${`server:${sid}`}, 'broadcast', '{}')`, `server:${sid}`)).rejects.toThrow();
    await as(m.id, (tx) => tx`insert into realtime.messages (topic, extension, payload) values (${`server:${sid}`}, 'broadcast', '{}')`, `server:${sid}`);
  });
});

describe("bots and webhooks", () => {
  test("bots post with their token and obey channel permissions", async () => {
    const o = await makeUser();
    const { sid, general } = await makeServer(o.id);
    const bot = await rpc<any>(o.id, "select public.create_bot('Helper', 'Says hi')");
    expect(bot.token).toMatch(/^gx\./);
    await expect(rpc(null, "select public.bot_send_message($1, $2, 'hi')", bot.token, general)).rejects.toThrow();
    await rpc(o.id, "select public.add_bot_to_server($1, $2)", bot.id, sid);
    const mid = await rpc<string>(null, "select public.bot_send_message($1, $2, 'beep boop')", bot.token, general);
    expect(mid).toBeTruthy();
    await expect(rpc(null, "select public.bot_send_message($1, $2, 'x')", bot.token + "x", general)).rejects.toThrow(/Invalid bot token/);
    const secret = await rpc<string>(o.id, "select public.create_channel($1, 'secret', 'text', null, true)", sid);
    await expect(rpc(null, "select public.bot_send_message($1, $2, 'x')", bot.token, secret)).rejects.toThrow();
    const msgs = await as(null, (tx) => tx`select * from public.bot_read_messages(${bot.token}, ${general})`);
    expect(msgs.length).toBeGreaterThan(0);
    const fresh = await rpc<string>(o.id, "select public.reset_bot_token($1)", bot.id);
    await expect(rpc(null, "select public.bot_me($1)", bot.token)).rejects.toThrow(/Invalid/);
    expect((await rpc<any>(null, "select public.bot_me($1)", fresh)).id).toBe(bot.id);
  });

  test("tokens are never readable", async () => {
    const o = await makeUser();
    await rpc(o.id, "select public.create_bot('Secret', '')");
    await expect(as(o.id, (tx) => tx`select token_hash from public.bot_apps`)).rejects.toThrow(/permission denied/);
  });

  test("slash commands round trip", async () => {
    const o = await makeUser();
    const m = await makeUser();
    const { sid, general, code } = await makeServer(o.id);
    await join(m.id, code);
    const bot = await rpc<any>(o.id, "select public.create_bot('Dice', '')");
    await rpc(o.id, "select public.add_bot_to_server($1, $2)", bot.id, sid);
    await rpc(null, "select public.bot_set_commands($1, $2::jsonb)", bot.token, [{ name: "roll", description: "Roll a die" }]);
    const iid = await rpc<string>(m.id, "select public.invoke_command($1, $2, 'roll', '{}')", general, bot.id);
    const pending = await as(null, (tx) => tx`select * from public.bot_poll_interactions(${bot.token})`);
    expect(pending.length).toBe(1);
    await rpc(null, "select public.bot_respond($1, $2, 'You rolled 4')", bot.token, iid);
    expect(await count(m.id, "select * from public.messages where channel_id = $1 and type = 'command'", general)).toBe(1);
  });

  test("webhooks need a valid token", async () => {
    const o = await makeUser();
    const { general } = await makeServer(o.id);
    const hook = await rpc<any>(o.id, "select public.create_webhook($1, 'Alerts')", general);
    await rpc(null, "select public.execute_webhook($1, $2, 'Server is up')", hook.id, hook.token);
    await expect(rpc(null, "select public.execute_webhook($1, $2, 'fake')", hook.id, "nope")).rejects.toThrow(/Invalid webhook/);
    expect(await count(o.id, "select * from public.messages where channel_id = $1 and webhook_id is not null", general)).toBe(1);
  });
});

describe("reports and moderation queue", () => {
  test("reports are visible to the reporter and the server's moderators only", async () => {
    const o = await makeUser();
    const a = await makeUser();
    const b = await makeUser();
    const { general, code } = await makeServer(o.id);
    await join(a.id, code);
    await join(b.id, code);
    const bad = await send(a.id, general, "rude thing");
    await as(b.id, (tx) => tx`insert into public.reports (reporter_id, target_type, target_id, reason) values (${b.id}, 'message', ${bad}, 'Harassment')`);
    expect(await count(b.id, "select * from public.reports where target_id = $1", bad)).toBe(1);
    expect(await count(o.id, "select * from public.reports where target_id = $1", bad)).toBe(1);
    expect(await count(a.id, "select * from public.reports where target_id = $1", bad)).toBe(0);
    const rid = await rpc<string>(o.id, "select id from public.reports where target_id = $1", bad);
    await expect(rpc(a.id, "select public.resolve_report($1, 'dismissed')", rid)).rejects.toThrow();
    await rpc(o.id, "select public.resolve_report($1, 'resolved', 'Deleted')", rid);
  });

  test("ban appeals", async () => {
    const o = await makeUser();
    const m = await makeUser();
    const { sid, code } = await makeServer(o.id);
    await join(m.id, code);
    await rpc(o.id, "select public.ban_member($1, $2, 'rude', 0)", sid, m.id);
    await rpc(m.id, "select public.submit_ban_appeal($1, 'Sorry, it won''t happen again')", sid);
    const appeal = await rpc<string>(o.id, "select id from public.ban_appeals where server_id = $1", sid);
    await rpc(o.id, "select public.review_ban_appeal($1, true)", appeal);
    expect((await join(m.id, code)).status).toBe("joined");
  });
});

describe("expressions", () => {
  test("only Manage Expressions can add emoji, and everyone can use them", async () => {
    const o = await makeUser();
    const m = await makeUser();
    const x = await makeUser();
    const { sid, code } = await makeServer(o.id);
    await join(m.id, code);
    await expect(as(m.id, (tx) => tx`insert into public.emojis (server_id, name, url) values (${sid}, 'nope', 'https://x/y.png')`)).rejects.toThrow();
    await as(o.id, (tx) => tx`insert into public.emojis (server_id, name, url, animated) values (${sid}, 'galaxy_spin', 'https://x/y.gif', true)`);
    expect(await count(x.id, "select * from public.emojis where server_id = $1", sid)).toBe(1);
  });
});
