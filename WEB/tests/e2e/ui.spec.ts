import { expect, test, type Page } from '@playwright/test'

const routes = [
  { path: '/', heading: /这里是小熙的大本营/ },
  { path: '/devices', heading: '你的小熙' },
  { path: '/companion', heading: '让小熙更懂你的节奏' },
  { path: '/bridge', heading: '连接这台电脑' },
  { path: '/memories', heading: '只留下真正有帮助的事' },
  { path: '/activity', heading: '发生过什么，一目了然' },
  { path: '/account', heading: '账户、用量和数据边界' },
]

async function expectNoDocumentOverflow(page: Page) {
  const dimensions = await page.evaluate(() => ({
    scrollWidth: document.documentElement.scrollWidth,
    clientWidth: document.documentElement.clientWidth,
  }))
  expect(dimensions.scrollWidth).toBeLessThanOrEqual(dimensions.clientWidth + 1)
}

for (const route of routes) {
  test(`${route.path} renders an honest, overflow-free state`, async ({ page }) => {
    const consoleErrors: string[] = []
    page.on('console', (message) => { if (message.type() === 'error') consoleErrors.push(message.text()) })

    await page.goto(route.path)

    await expect(page.getByRole('heading', { level: 1, name: route.heading })).toBeVisible()
    await expect(page.getByText('本地预览', { exact: true })).toBeVisible()
    await expectNoDocumentOverflow(page)
    expect(consoleErrors).toEqual([])
  })
}

test('companion settings update only the preview state', async ({ page }) => {
  await page.goto('/companion')

  const quietMode = page.getByRole('button', { name: '安静陪伴' })
  await quietMode.click()

  await expect(quietMode).toHaveAttribute('aria-pressed', 'true')
  await expect(page.getByRole('status')).toContainText('已更新本地预览')
})

test('memory removal requires explicit confirmation', async ({ page }) => {
  await page.goto('/memories')

  await page.getByRole('button', { name: '删除音乐偏好示例' }).click()
  const dialog = page.getByRole('alertdialog', { name: '确认删除音乐偏好示例' })
  await expect(dialog).toBeVisible()
  await dialog.getByRole('button', { name: '取消' }).click()
  await expect(dialog).toBeHidden()
  await expect(page.getByText('音乐偏好示例')).toBeVisible()
})

test('memory editing keeps changes inside the preview repository', async ({ page }) => {
  await page.goto('/memories')

  await page.getByRole('button', { name: '编辑音乐偏好示例' }).click()
  await page.getByLabel('记忆名称').fill('专注音乐偏好')
  await page.getByLabel('记忆内容').fill('工作时喜欢没有歌词的轻音乐。')
  await page.getByRole('button', { name: '保存更改' }).click()

  await expect(page.getByText('专注音乐偏好')).toBeVisible()
  await expect(page.getByText('工作时喜欢没有歌词的轻音乐。')).toBeVisible()
  await expect(page.getByText('本地预览', { exact: true })).toBeVisible()
})

test('mobile navigation replaces the desktop sidebar', async ({ page }, testInfo) => {
  test.skip(!testInfo.project.name.startsWith('mobile-'), 'mobile-only assertion')
  await page.goto('/')

  await expect(page.locator('.sidebar')).toBeHidden()
  await expect(page.getByRole('navigation', { name: '移动端导航' })).toBeVisible()
})
