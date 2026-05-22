// Expected POST body from front-zanaflex.html:
//   { chatInput, sessionId, userId, userName?, userRole? }
// Re-inject canonical [CONTEXTO DO USUÁRIO: ...] block so the chat-message
// trigger (migration 010) can link rows to users.
const b = $input.first().json.body || $input.first().json;
if (!b.userId)    throw new Error('userId is required');
if (!b.sessionId) throw new Error('sessionId is required');
if (!b.chatInput) throw new Error('chatInput is required');
const ctx = `[CONTEXTO DO USUÁRIO: nome="${b.userName || ''}" papel="${b.userRole || 'visualizador'}" ID="${b.userId}"]`;
const chatInput = b.chatInput.includes('[CONTEXTO DO USUÁRIO')
  ? b.chatInput
  : `${ctx}\n\n${b.chatInput}`;
return {
  chatInput,
  sessionId: b.sessionId,
  userId:    b.userId,
  userName:  b.userName || '',
  userRole:  b.userRole || 'visualizador',
};
