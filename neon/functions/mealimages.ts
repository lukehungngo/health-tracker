import { S3Client, GetObjectCommand, PutObjectCommand } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { createRemoteJWKSet, jwtVerify } from "jose";

const authBase = process.env.NEON_AUTH_BASE_URL;
const jwksURL = process.env.NEON_AUTH_JWKS_URL;
if (!authBase || !jwksURL) throw new Error("Neon Auth configuration is required");
const jwks = createRemoteJWKSet(new URL(jwksURL));
const issuer = new URL(authBase).origin;
const s3 = new S3Client({ forcePathStyle: true });
const bucket = "meal-images";

export default {
  async fetch(request: Request): Promise<Response> {
    if (request.method !== "POST") return new Response("Method not allowed", { status: 405 });
    const bearer = request.headers.get("authorization")?.match(/^Bearer (.+)$/i)?.[1];
    if (!bearer) return new Response("Unauthorized", { status: 401 });
    let userID: string;
    try {
      const { payload } = await jwtVerify(bearer, jwks, { issuer });
      if (typeof payload.sub !== "string" || !/^[0-9a-f-]{36}$/i.test(payload.sub)) throw new Error("Invalid subject");
      userID = payload.sub.toLowerCase();
    } catch {
      return new Response("Unauthorized", { status: 401 });
    }
    let input: { action?: unknown; path?: unknown };
    try {
      input = await request.json();
    } catch {
      return new Response("Invalid JSON", { status: 400 });
    }
    const { action, path } = input;
    if (typeof path !== "string" || !new RegExp(`^${userID}/[0-9a-zA-Z_-]+\\.jpe?g$`).test(path)) {
      return new Response("Invalid image path", { status: 400 });
    }
    if (action !== "upload" && action !== "download") return new Response("Invalid action", { status: 400 });
    try {
      const command = action === "upload"
        ? new PutObjectCommand({ Bucket: bucket, Key: path, ContentType: "image/jpeg" })
        : new GetObjectCommand({ Bucket: bucket, Key: path });
      const url = await getSignedUrl(s3, command, { expiresIn: 600 });
      return Response.json({ url });
    } catch {
      return new Response("Image storage unavailable", { status: 503 });
    }
  },
};
