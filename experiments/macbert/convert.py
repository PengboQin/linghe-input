"""Pinned local safe weights -> bounded Chinese correction scorer, Mac only."""
import pathlib,torch,numpy as np,coremltools as ct,json,time
from transformers import BertConfig,BertForMaskedLM,BertTokenizer
from safetensors.torch import load_file
from coremltools.optimize.coreml import OptimizationConfig,OpLinearQuantizerConfig,linear_quantize_weights
root=pathlib.Path(__file__).resolve().parents[2];source=root/'vendor/semantic/macbert4csc';out=root/'artifacts/macbert';out.mkdir(parents=True,exist_ok=True)
torch.set_num_threads(2);config=BertConfig.from_json_file(str(source/'config.json'));config._attn_implementation='eager'
model=BertForMaskedLM(config);state=load_file(source/'model.safetensors');state.pop('bert.embeddings.position_ids',None)
# Safetensors omits aliases of the tied embeddings/decoder and output biases.
state.setdefault('cls.predictions.decoder.weight',state['bert.embeddings.word_embeddings.weight'])
state.setdefault('cls.predictions.decoder.bias',state['cls.predictions.bias'])
model.load_state_dict(state);model.eval();tokenizer=BertTokenizer(vocab_file=str(source/'vocab.txt'),do_lower_case=True)
class Scorer(torch.nn.Module):
 def __init__(self,m):super().__init__();self.model=m
 def forward(self,input_ids,attention_mask):
  hidden=self.model.bert.embeddings(input_ids=input_ids)
  bias=(1-attention_mask[:,None,None,:].float())*-10000.0
  hidden=self.model.bert.encoder(hidden,attention_mask=bias,return_dict=False)[0]
  logits=self.model.cls(hidden)
  # CSC is trained on observed (unmasked) tokens. Export only their likelihoods.
  return torch.gather(torch.log_softmax(logits,dim=-1),2,input_ids.unsqueeze(-1)).squeeze(-1)
wrapper=Scorer(model).eval();sample=tokenizer(['今天心情很好','今天新情很好','我们一起吃饭','我们一起吃反'],padding='max_length',max_length=48,return_tensors='pt');ids=sample['input_ids'];mask=sample['attention_mask']
with torch.inference_mode():
 ref=wrapper(ids,mask).numpy();original=torch.gather(model(ids,attention_mask=mask).logits.log_softmax(-1),2,ids.unsqueeze(-1)).squeeze(-1).numpy()
 assert np.max(np.abs(ref-original))<0.001
 trace=torch.jit.trace(wrapper,(ids,mask))
precision=ct.transform.FP16ComputePrecision(op_selector=lambda op:op.op_type not in ['layer_norm','log_softmax','reduce_log_sum_exp'])
converted=ct.convert(trace,inputs=[ct.TensorType(name='input_ids',shape=(4,48),dtype=np.int32),ct.TensorType(name='attention_mask',shape=(4,48),dtype=np.int32)],outputs=[ct.TensorType(name='token_log_probs')],minimum_deployment_target=ct.target.macOS13,convert_to='mlprogram',compute_precision=precision,compute_units=ct.ComputeUnit.CPU_ONLY)
converted.short_description='PrivateInput MacBERT Chinese spelling plausibility; local candidate scoring.'
converted.user_defined_metadata['upstream']='shibing624/macbert4csc-base-chinese@615e6e09ef9a69ec487bc7c641ec3a311e2c11b9'
compressed=linear_quantize_weights(converted,config=OptimizationConfig(global_config=OpLinearQuantizerConfig(mode='linear_symmetric',dtype=np.int8)))
compressed.save(str(out/'MacBERT.mlpackage'))
inputs={'input_ids':ids.numpy().astype(np.int32),'attention_mask':mask.numpy().astype(np.int32)}
times=[]
for _ in range(4):
 start=time.monotonic();pred=compressed.predict(inputs)['token_log_probs'];times.append(time.monotonic()-start)
assert np.isfinite(pred).all()
active=mask.numpy().astype(bool);error=float(np.max(np.abs(pred[active]-ref[active])))
report={'revision':'615e6e09ef9a69ec487bc7c641ec3a311e2c11b9','batch':4,'length':48,'maxActiveTokenLogProbError':error,'predictionSeconds':times,'scores':[float(pred[i,1:len(tokenizer.encode(t))-1].mean()) for i,t in enumerate(['今天心情很好','今天新情很好','我们一起吃饭','我们一起吃反'])],'packageBytes':sum(p.stat().st_size for p in (out/'MacBERT.mlpackage').rglob('*') if p.is_file())}
(root/'evidence/macbert27-20261016/conversion.json').write_text(json.dumps(report,indent=2));print(report,flush=True)
