import { Hono } from 'hono';
import { deleteResource, deleteThread, getThreadMessages } from '../memory/store.ts';

export const threadRoute = new Hono();

threadRoute.get('/thread/:id', async (c) => {
  const id = c.req.param('id');
  try {
    const messages = await getThreadMessages(id);
    return c.json({ threadId: id, messages });
  } catch (err) {
    return c.json({ error: 'thread_fetch_failed', detail: String(err) }, 500);
  }
});

threadRoute.delete('/thread/:id', async (c) => {
  const id = c.req.param('id');
  try {
    await deleteThread(id);
    return c.json({ ok: true });
  } catch (err) {
    return c.json({ error: 'thread_delete_failed', detail: String(err) }, 500);
  }
});

threadRoute.delete('/resource/:id', async (c) => {
  const id = c.req.param('id');
  try {
    await deleteResource(id);
    return c.json({ ok: true });
  } catch (err) {
    return c.json({ error: 'resource_delete_failed', detail: String(err) }, 500);
  }
});
