/** @type {import('next').NextConfig} */
const nextConfig = {
  output: "standalone",

  async rewrites() {
    return [
      {
        source: "/api/knowledge/:path*",
        destination: `${process.env.BACKEND_URL || "http://localhost:8080"}/api/knowledge/:path*`,
      },
    ];
  },
};

export default nextConfig;
