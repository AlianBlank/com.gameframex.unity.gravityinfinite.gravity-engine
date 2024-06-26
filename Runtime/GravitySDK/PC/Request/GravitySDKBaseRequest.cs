﻿using System;
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
using System.Collections.Generic;
using GravitySDK.PC.Constant;
using GravitySDK.PC.Utils;
using System.IO;
using System.Text;
using System.IO.Compression;
using System.Runtime.Serialization;
using UnityEngine.Networking;
using System.Collections;

namespace GravitySDK.PC.Request
{
    /*
     * 枚举post上报数据的形式,枚举值表示json和form表单
     */
    enum POST_TYPE
    {
        JSON,
        FORM
    };

    public abstract class GravitySDKBaseRequest
    {
        private string mURL;
        private IList<Dictionary<string, object>> mData;

        public GravitySDKBaseRequest(string url, IList<Dictionary<string, object>> data)
        {
            mURL = url;
            mData = data;
        }

        public GravitySDKBaseRequest(string url)
        {
            mURL = url;
        }

        public void SetData(IList<Dictionary<string, object>> data)
        {
            this.mData = data;
        }

        public string URL()
        {
            return mURL;
        }

        public IList<Dictionary<string, object>> Data()
        {
            return mData;
        }

        /** 
         * 初始化接口
         */
        public static void GetConfig(string url, ResponseHandle responseHandle)
        {
            if (!GravitySDKUtil.IsValiadURL(url))
            {
                GravitySDKLogger.Print("invalid url");
            }

            HttpWebRequest request = (HttpWebRequest) WebRequest.Create(url);
            request.Method = "GET";
            HttpWebResponse response = (HttpWebResponse) request.GetResponse();
            var responseResult = new StreamReader(response.GetResponseStream()).ReadToEnd();
            if (responseResult != null)
            {
                GravitySDKLogger.Print("Request URL=" + url);
                GravitySDKLogger.Print("Response:=" + responseResult);
            }
        }

        public bool MyRemoteCertificateValidationCallback(System.Object sender, X509Certificate certificate,
            X509Chain chain, SslPolicyErrors sslPolicyErrors)
        {
            bool isOk = true;
            // If there are errors in the certificate chain,
            // look at each error to determine the cause.
            if (sslPolicyErrors != SslPolicyErrors.None)
            {
                for (int i = 0; i < chain.ChainStatus.Length; i++)
                {
                    if (chain.ChainStatus[i].Status == X509ChainStatusFlags.RevocationStatusUnknown)
                    {
                        continue;
                    }

                    chain.ChainPolicy.RevocationFlag = X509RevocationFlag.EntireChain;
                    chain.ChainPolicy.RevocationMode = X509RevocationMode.Online;
                    chain.ChainPolicy.UrlRetrievalTimeout = new TimeSpan(0, 1, 0);
                    chain.ChainPolicy.VerificationFlags = X509VerificationFlags.AllFlags;
                    bool chainIsValid = chain.Build((X509Certificate2) certificate);
                    if (!chainIsValid)
                    {
                        isOk = false;
                        break;
                    }
                }
            }

            return isOk;
        }

        abstract public IEnumerator SendData_2(ResponseHandle responseHandle, IList<Dictionary<string, object>> data);

        public static IEnumerator GetWithFORM_2(string url, Dictionary<string, object> param,
            ResponseHandle responseHandle)
        {
            string uri = url;
            if (param != null)
            {
                uri = uri + "&data=" + GravitySDKJSON.Serialize(param);
            }

            using (UnityWebRequest webRequest = UnityWebRequest.Get(uri))
            {
                webRequest.timeout = 30;
                webRequest.SetRequestHeader("Content-Type", "application/x-www-form-urlencoded");

                GravitySDKLogger.Print("Request URL=" + uri);

                // Request and wait for the desired page.
                yield return webRequest.SendWebRequest();

                Dictionary<string, object> resultDict = null;
#if UNITY_2020_1_OR_NEWER
                switch (webRequest.result)
                {
                    case UnityWebRequest.Result.ConnectionError:
                    case UnityWebRequest.Result.DataProcessingError:
                    case UnityWebRequest.Result.ProtocolError:
                        GravitySDKLogger.Print("Error response : " + webRequest.error);
                        break;
                    case UnityWebRequest.Result.Success:
                        GravitySDKLogger.Print("Response : " + webRequest.downloadHandler.text);
                        if (!string.IsNullOrEmpty(webRequest.downloadHandler.text))
                        {
                            resultDict = GravitySDKJSON.Deserialize(webRequest.downloadHandler.text);
                        }

                        break;
                }
#else
                if (webRequest.isHttpError || webRequest.isNetworkError)
                {
                    GravitySDKLogger.Print("Error response : " + webRequest.error);
                }
                else
                {
                    GravitySDKLogger.Print("Response : " + webRequest.downloadHandler.text);
                    if (!string.IsNullOrEmpty(webRequest.downloadHandler.text)) 
                    {
                        resultDict = GravitySDKJSON.Deserialize(webRequest.downloadHandler.text);
                    } 
                }
#endif
                if (responseHandle != null)
                {
                    responseHandle(resultDict);
                }
            }
        }
    }
}