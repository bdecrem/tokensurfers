import { NextRequest } from 'next/server'
import { handleAuth } from '@/lib/surf/authRoutes'

export const runtime = 'nodejs'
export async function POST(req: NextRequest) { return handleAuth(req, 'signup') }
