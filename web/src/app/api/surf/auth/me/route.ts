import { NextRequest, NextResponse } from 'next/server'
import { getSurfUser } from '@/lib/surf/auth'

export const runtime = 'nodejs'
export async function GET(req: NextRequest) {
  const user = await getSurfUser(req)
  return NextResponse.json({ user }, { headers: { 'cache-control': 'no-store' } })
}
