// Subscribe to one order's status over WebSocket, using the graphql-transport-ws
// protocol, and print every event until the first one arrives or time runs out.
//
//   node scripts/subscribe.mjs 5
const orderId = process.argv[2] ?? '1';
const ws = new WebSocket('ws://localhost:8201/graphql-ws', 'graphql-transport-ws');
const timer = setTimeout(() => { console.log('no event within 20 seconds'); process.exit(1); }, 20000);

ws.onopen = () => ws.send(JSON.stringify({type: 'connection_init'}));
ws.onmessage = (event) => {
  const msg = JSON.parse(event.data);
  if (msg.type === 'connection_ack') {
    console.log('connected, subscribed to order ' + orderId);
    ws.send(JSON.stringify({
      id: '1',
      type: 'subscribe',
      payload: {query: `subscription { orderStatus(orderId: ${orderId}) { id status } }`},
    }));
  } else if (msg.type === 'next') {
    console.log('event: ' + JSON.stringify(msg.payload.data));
    clearTimeout(timer);
    ws.close();
    process.exit(0);
  } else if (msg.type === 'error') {
    console.log('error: ' + JSON.stringify(msg.payload));
    process.exit(1);
  }
};
