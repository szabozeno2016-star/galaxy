import { SQL } from "bun";

const url = process.env.DATABASE_URL ?? "postgres://postgres@127.0.0.1:54329/galaxy_test";
export const db = new SQL(url.replace(/\?host=.*$/, "").replace("@localhost", "@127.0.0.1"));

let counter = 0;

/** Creates a real account the way Supabase Auth does (insert into auth.users). */
export async function makeUser(name?: string): Promise<{ id: string; username: string }> {
  counter++;
  const id = crypto.randomUUID();
  const username = (name ?? "user") + "_" + counter + "_" + Math.floor(Math.random() * 1e6);
  await db`insert into auth.users (id, email, raw_user_meta_data)
           values (${id}, ${username + "@example.test"}, ${{ username, display_name: name ?? "Test" }})`;
  const [p] = await db`select username from public.profiles where id = ${id}`;
  return { id, username: p.username };
}

type Tx = any;

/** Runs `fn` as a signed-in user (or anon when uid is null), with RLS applied. */
export async function as<T>(uid: string | null, fn: (tx: Tx) => Promise<T>, topic?: string): Promise<T> {
  return db.begin(async (tx: Tx) => {
    await tx.unsafe(`set local role ${uid ? "authenticated" : "anon"}`);
    const claims = JSON.stringify(uid ? { sub: uid, role: "authenticated", session_id: "s-" + uid } : { role: "anon" });
    await tx`select set_config('request.jwt.claims', ${claims}, true)`;
    if (topic) await tx`select set_config('realtime.topic', ${topic}, true)`;
    return fn(tx);
  });
}

/** Calls an RPC as a user and returns the single value it produced. */
export async function rpc<T = any>(uid: string | null, sql: string, ...params: any[]): Promise<T> {
  return as(uid, async (tx) => {
    const rows = await tx.unsafe(sql, params);
    if (!rows.length) return undefined as T;
    const first = rows[0];
    const keys = Object.keys(first);
    return (keys.length === 1 ? first[keys[0]] : first) as T;
  });
}

export function perm(name: string): bigint {
  const bits = [
    "VIEW_CHANNEL", "SEND_MESSAGES", "MANAGE_MESSAGES", "MANAGE_CHANNELS", "MANAGE_ROLES", "MANAGE_SERVER",
    "KICK_MEMBERS", "BAN_MEMBERS", "CREATE_INVITE", "ATTACH_FILES", "ADD_REACTIONS", "MENTION_EVERYONE",
    "CONNECT", "SPEAK", "VIDEO", "MUTE_MEMBERS", "MOVE_MEMBERS", "MANAGE_EXPRESSIONS", "MANAGE_EVENTS",
    "MANAGE_WEBHOOKS", "MODERATE_MEMBERS", "VIEW_AUDIT_LOG", "ADMINISTRATOR", "READ_HISTORY", "CREATE_THREADS",
    "SEND_IN_THREADS", "USE_SOUNDBOARD", "STREAM", "CHANGE_NICKNAME", "MANAGE_NICKNAMES",
  ];
  const i = bits.indexOf(name);
  if (i < 0) throw new Error("unknown perm " + name);
  return 1n << BigInt(i);
}

/** Creates a server owned by `owner` and returns its ids. */
export async function makeServer(owner: string, template = "default") {
  const sid: string = await rpc(owner, "select public.create_server($1, null, $2)", "Test Server", template);
  const general = await rpc<string>(owner, "select system_channel_id from public.servers where id = $1", sid);
  const everyone = await rpc<string>(owner, "select id from public.roles where server_id = $1 and is_default", sid);
  const code = await rpc<string>(owner,
    "insert into public.invites (server_id, created_by) values ($1, auth.uid()) returning code", sid);
  return { sid, general, everyone, code };
}

export async function join(uid: string, code: string) {
  return rpc(uid, "select public.join_server($1)", code);
}

export async function send(uid: string, channel: string, content: string, extra: Record<string, any> = {}) {
  return as(uid, async (tx) => {
    const [row] = await tx`insert into public.messages ${tx({ channel_id: channel, author_id: uid, content, ...extra })} returning id`;
    return row.id as string;
  });
}

export async function count(uid: string | null, sql: string, ...params: any[]): Promise<number> {
  return Number(await rpc(uid, `select count(*)::int from (${sql}) x`, ...params));
}
