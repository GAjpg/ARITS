// Keep connection failures separate from map validation errors; never retry uploads implicitly.
export const offlineMessage = '无法连接本机工作台。请双击“启动通行空间工作台.command”，启动后刷新页面再导入。';
export const restartedMessage = '本机工作台已重启或页面凭证已失效，请刷新页面后再试。';
async function requestResponse(url, options = {}, {token, connectionChanged = () => {}, fetchImpl = globalThis.fetch} = {}) {
  let response;
  try {
    response = await fetchImpl(url, {...options, headers:{...options.headers, 'X-Viewer-Token':token}});
  } catch {
    connectionChanged('offline', offlineMessage);
    throw new Error(offlineMessage);
  }
  if (response.status === 403) {
    connectionChanged('expired', restartedMessage);
    throw new Error(restartedMessage);
  }
  connectionChanged('online', '');
  return response;
}
export async function requestJSON(url, options = {}, context = {}) {
  const response = await requestResponse(url, options, context);
  let data;
  try { data = await response.json(); }
  catch { throw new Error('本机工作台返回了异常响应，请刷新页面；若仍失败，请查看服务日志。'); }
  if (!response.ok) throw new Error(data.error || `工作台处理失败（${response.status}）`);
  return data;
}

export async function requestBinary(url, context = {}) {
 const response=await requestResponse(url,{},context);
 if(!response.ok)throw Error(`点云加载失败（${response.status}）`);
 return response.arrayBuffer();
}
